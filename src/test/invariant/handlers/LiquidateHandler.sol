// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InvariantTestBase} from "../InvariantTestBase.sol";
import {BaseHandler, GhostVariableStorage, USERS_CATEGORY} from "./BaseHandler.sol";

import {ICDPVaultBase} from "../../../interfaces/ICDPVault.sol";

import {calculateDebt} from "../../../CDPVault.sol";
import {CDM, getDebt} from "../../../CDM.sol";
import {CDPVaultWrapper} from "../CDPVaultWrapper.sol";
import {WAD, min, wdiv, wmul, mul} from "../../../utils/Math.sol";

contract LiquidateHandler is BaseHandler {
    uint256 internal constant COLLATERAL_PER_POSITION = 1_000_000 ether;
    
    uint256 public immutable creditReserve = 100_000_000_000_000 ether;
    uint256 public immutable collateralReserve = 100_000_000_000_000 ether;
    
    uint256 public immutable maxCreateUserAmount = 1;
    uint256 public immutable minLiquidateUserAmount = 1;

    uint256 public immutable maxCollateralRatio = 2 ether;

    address public liquidatedPosition;
    uint256 public preLiquidationDebt;
    uint256 public postLiquidationDebt;
    uint256 public creditPaid;
    uint256 public accruedBadDebt;

    CDM public cdm;
    CDPVaultWrapper public vault;
    IERC20 public token;
    address public buffer;

    uint64 internal immutable liquidationRatio;
    uint64 internal immutable targetHealthFactor;
    uint256 internal immutable liquidationDiscount;
    uint64 internal immutable liquidationPenalty;

    function liquidationPrice(uint256 collateral, uint256 normalDebt) internal view returns (uint256 spotPrice) {
        spotPrice = wmul(wdiv(wmul(normalDebt, uint256(liquidationRatio)), collateral), uint256(0.9 ether));
    }

    constructor(
        CDPVaultWrapper vault_, 
        InvariantTestBase testContract_, 
        GhostVariableStorage ghostStorage_,
        uint64 positionLiquidationRatio_,
        uint64 targetHealthFactor_,
        uint64 liquidationPenalty_
    ) BaseHandler ("LiquidateHandler", testContract_, ghostStorage_) {
        vault = vault_;
        cdm = CDM(address(vault_.cdm()));
        buffer = address(vault_.buffer());
        token = vault.token();
        liquidationRatio = positionLiquidationRatio_;
        liquidationPenalty = liquidationPenalty_;
        targetHealthFactor = targetHealthFactor_;
        ( ,liquidationDiscount) = vault.liquidationConfig(); 
    }

    function getTargetSelectors() public pure virtual override returns (bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](2);
        names = new string[](2);
        selectors[0] = this.createPositions.selector;
        names[0] = "createPositions";

        selectors[1] = this.liquidateRandom.selector;
        names[1] = "liquidateRandom";
    }

    function createPositions(uint256 seed, uint256 healthFactorSeed) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        // reset state 
        liquidatedPosition = address(0);
        preLiquidationDebt = 0;
        postLiquidationDebt = 0;
        creditPaid = 0;
        accruedBadDebt = 0;

        for (uint256 i = 0; i < maxCreateUserAmount; i++) {
            address user = address(uint160(uint256(keccak256(abi.encode(msg.sender, seed, i)))));
            addActor(USERS_CATEGORY, user);

            // bound the health factor and calculate collateral and debt, randomize the health factor seed
            uint256 minCollateralRatio = liquidationRatio;
            uint256 collateralRatio = bound(uint256(keccak256(abi.encode(healthFactorSeed, user))), minCollateralRatio, maxCollateralRatio);
            uint256 collateral = COLLATERAL_PER_POSITION;
            uint256 debt = wdiv(collateral, collateralRatio);
            vault.modifyPermission(user, true);

            // create the position
            vm.startPrank(user);
            vault.modifyCollateralAndDebt({
                owner:user, 
                collateralizer: address(this), 
                creditor: user, 
                deltaCollateral: int256(collateral),
                deltaNormalDebt: int256(debt)
            });
            vm.stopPrank();
        }

        trackCallEnd(msg.sig);
    }

    function liquidateRandom(uint256 randomSeed) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        address user = getRandomActor(USERS_CATEGORY, randomSeed);
        if(user == address(0)) return;

        (uint256 collateral, uint256 normalDebt) = vault.positions(user);
        if(collateral == 0 || normalDebt == 0) return;
 
        uint256 repayAmount = bound(randomSeed, minLiquidateUserAmount, normalDebt * 2);
        if(repayAmount == 0) return;

        _liquidatePosition(user, repayAmount);

        trackCallEnd(msg.sig);
    }

    /// ======== Value tracking helper functions ======== ///

    function getPositionHealth(
        address position
    ) public view returns (uint256 prevHealth, uint256 currentHealth) {
        (bytes32 prevHealthBytes, bytes32 currentHealthBytes) = getTrackedValue(keccak256(abi.encodePacked("positionHealth", position)));
        return (uint256(prevHealthBytes), uint256(currentHealthBytes));
    }

    function getPositionDebt(
        address position
    ) public view returns (uint256 prevDebt, uint256 currentDebt) {
        (bytes32 prevDebtBytes, bytes32 currentDebtBytes) = getTrackedValue(keccak256(abi.encodePacked("positionDebt", position)));
        return (uint256(prevDebtBytes), uint256(currentDebtBytes));
    }

    function getRepayAmount(address position) public view returns (uint256 amount) {
        return uint256(getGhostValue(keccak256(abi.encodePacked("repayAmount", position))));
    }

    function _trackPositionHealth(address position, uint256 spot) private returns (uint256 currentHealth){
        (uint256 collateral, uint256 normalDebt) = vault.positions(position);
        uint64 rateAccumulator = vault.virtualRateAccumulator();

        uint256 debt = calculateDebt(normalDebt, rateAccumulator);
        if (collateral == 0 || normalDebt == 0) {
            currentHealth = type(uint256).max;
        } else {
            currentHealth = wdiv(wdiv(wmul(collateral, spot), debt), liquidationRatio);
        }
        trackValue(keccak256(abi.encodePacked("positionHealth", position)), bytes32(currentHealth));
    }

    function _trackPositionNormalDebt(address position) private returns (uint256 normalDebt) {
        ( , normalDebt) = vault.positions(position);
        trackValue(keccak256(abi.encodePacked("positionDebt", position)), bytes32(normalDebt));
    }

    function _setRepayAmount(address position, uint256 repayAmount) private {
        setGhostValue(keccak256(abi.encodePacked("repayAmount", position)), bytes32(repayAmount));
    }

    /// ======== Liquidation helper functions ======== ///

    function _liquidatePosition(
        address position, uint256 repayAmount
    ) private {

        uint256 newSpotPrice =  _getLiquidationPrice(position);
        testContract.setOraclePrice(newSpotPrice);
        liquidatedPosition = position;

        // track the debt and health of the position pre liquidation
        uint256 normalDebt = _trackPositionNormalDebt(position);
        uint64 rateAccumulator = vault.virtualRateAccumulator();
        uint256 debt = calculateDebt(normalDebt, rateAccumulator);
        preLiquidationDebt = debt;
        
        _trackPositionHealth(position, newSpotPrice);

        _setRepayAmount(position, repayAmount);

        (int256 balance, ) = cdm.accounts(address(this));

        // accruedBadDebt = _getBadDebt(position, newSpotPrice, repayAmount);
        vault.liquidatePosition(position, repayAmount);
        (int256 finalBalance, ) = cdm.accounts(address(this));

        // track the debt and health of the position post liquidation
        postLiquidationDebt = _trackPositionNormalDebt(position);
        _trackPositionHealth(position, newSpotPrice);

        creditPaid = uint256(balance - finalBalance);

        uint256 deltaDebt = preLiquidationDebt - postLiquidationDebt;
        if (deltaDebt > creditPaid) {
            accruedBadDebt = deltaDebt - wmul(creditPaid, liquidationPenalty);
        } else {
            accruedBadDebt = 0;
        }
        
        testContract.setOraclePrice(WAD);
    }

    function _getBadDebt(address position, uint256 spotPrice, uint256 repayAmount) view internal returns (uint256 badDebt) {
        (uint256 collateral, uint256 normalDebt) = vault.positions(position);
        uint256 discountedPrice = wmul(spotPrice, liquidationDiscount);
        uint256 takeCollateral = wdiv(repayAmount, discountedPrice);

        uint64 rateAccumulator = vault.virtualRateAccumulator();
        uint256 debt = calculateDebt(normalDebt, rateAccumulator);
        uint256 deltaDebt = wmul(repayAmount, liquidationPenalty);

        // account for bad debt
        if (takeCollateral > collateral) {
            takeCollateral = collateral;
            repayAmount = wmul(takeCollateral, discountedPrice);
            deltaDebt = debt;
        }

        if (deltaDebt > takeCollateral) {
            badDebt = deltaDebt - takeCollateral;
        }
    } 

    function _getLiquidationPrice(
        address position
    ) private view returns (uint256 liquidationPrice_) {
        liquidationPrice_ = WAD;
        (uint256 collateral, uint256 normalDebt) = vault.positions(position);
        uint256 currentLiqPrice = liquidationPrice(collateral, normalDebt);
        if(liquidationPrice_ > currentLiqPrice) {
            liquidationPrice_ = currentLiqPrice;
        }

        return wmul(liquidationPrice_, uint256(0.9 ether));
    }
}