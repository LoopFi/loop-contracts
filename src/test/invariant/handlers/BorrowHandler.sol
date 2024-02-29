// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BaseHandler.sol";
import {InvariantTestBase} from "../InvariantTestBase.sol";
import {CDPVaultWrapper} from "../CDPVaultWrapper.sol";

import {InterestRateModel} from "../../../InterestRateModel.sol";
import {ICDPVaultBase} from "../../../interfaces/ICDPVault.sol";
import {wdiv, WAD} from "../../../utils/Math.sol";
import {CDM} from "../../../CDM.sol";

contract BorrowHandler is BaseHandler {
    uint256 public immutable maxSpotPrice = 100 ether;
    uint256 public immutable minSpotPrice = 0.001 ether;
    uint256 public immutable maximumDeposit = 1_000_000 ether;
    uint256 public immutable creditReserve = 100_000_000_000 ether;
    uint256 public immutable collateralReserve = 100_000_000_000 ether;

    CDM public cdm;
    CDPVaultWrapper public vault;
    IERC20 public token;

    uint256 public limitOrderPriceIncrement = 0.25 ether;

    mapping (address owner => uint256 limitOrderPrice) activeLimitOrders;

    function liquidationPrice(ICDPVaultBase vault_) internal returns (uint256) {
        (, uint64 liquidationRatio) = vault_.vaultConfig();
        return wdiv(vault_.spotPrice(), uint256(liquidationRatio));
    }

    constructor(CDPVaultWrapper vault_, InvariantTestBase testContract_, GhostVariableStorage ghostStorage_) BaseHandler("BorrowHandler", testContract_, ghostStorage_) {
        vault = vault_;
        cdm = CDM(address(vault_.cdm()));
        token = vault.token();

        // initialize the rate accumulator
        _trackRateAccumulator();
    }

    function getTargetSelectors() public pure virtual override returns (bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](5);
        names = new string[](5);
        selectors[0] = this.borrow.selector;
        names[0] = "borrow";

        selectors[1] = this.partialRepay.selector;
        names[1] = "partialRepay";

        selectors[2] = this.repay.selector;
        names[2] = "repay";

        selectors[3] = this.changeSpotPrice.selector;
        names[3] = "changeSpotPrice";

        selectors[4] = this.changeBaseRate.selector;
        names[4] = "changeBaseRate";
    }

    // Account (with or without existing position) deposits collateral and increases debt
    function borrow(uint256 collateralSeed, uint256 warpAmount) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        address owner = msg.sender;
        // register sender as a user
        addActor(USERS_CATEGORY, owner);

        (uint128 debtFloor,) = vault.vaultConfig();
        uint256 collateral = bound(collateralSeed, debtFloor, maximumDeposit);

        // deposit collateral if needed
        token.approve(address(vault), collateral);
        vault.deposit(owner, collateral);

        (int256 deltaCollateral, int256 deltaNormalDebt, uint256 creditNeeded) = vault.getMaximumDebtForCollateral(owner, owner, owner, int256(collateral));

        if (creditNeeded != 0){
            testContract.createCredit(owner, creditNeeded);
        }

        _setupPermissions(owner, owner);

        vm.startPrank(owner);
        vault.modifyCollateralAndDebt(owner, owner, owner, deltaCollateral, deltaNormalDebt);
        vm.stopPrank();
        _trackUserRateAccumulator(owner);
        _trackRateAccumulator();
        
        warpInterval(warpAmount);

        trackCallEnd(msg.sig);
    }

    // Partially repays debt and withdraws collateral
    function partialRepay(uint256 userSeed, uint256 percent) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        percent = bound(percent, 1, 99);

        address owner = getRandomActor(USERS_CATEGORY, userSeed);
        
        if(owner == address(0)) return;

        _setupPermissions(owner, address(this));
        
        (, uint256 normalDebt) = vault.positions(owner);
        if(normalDebt == 0) return;
        
        (uint128 debtFloor, ) = vault.vaultConfig();

        uint256 amount = (normalDebt * percent) / 100;
        amount = bound(amount, 0, cdm.creditLine(address(this)));

        // full replay if we are below debt floor
        if(int256(normalDebt - amount) < int256(int128(debtFloor))) amount = normalDebt;
        vault.modifyCollateralAndDebt(owner, owner, address(this), 0, -int256(amount));

        _trackUserRateAccumulator(owner);
        _trackRateAccumulator();

        trackCallEnd(msg.sig);
    }

    // Fully repay debt and withdraws collateral
    function repay(uint256 userSeed) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        // same as partialRepay, but 100%
        // users are removed from the list if they have no debt
        address owner = getRandomActor(USERS_CATEGORY, userSeed);
        if(owner == address(0)) return;

        _setupPermissions(owner, address(this));
        
        (, uint256 normalDebt) = vault.positions(owner);

        if(normalDebt == 0) return;
        
        normalDebt = bound(normalDebt, 0, cdm.creditLine(address(this)));
        vault.modifyCollateralAndDebt(owner, owner, address(this), 0, -int256(normalDebt));

        _trackUserRateAccumulator(owner);
        _trackRateAccumulator();

        trackCallEnd(msg.sig);
    }

    // Governance updates the base interest rate
    function changeBaseRate(uint256 baseRate) public {
        trackCallStart(msg.sig);
        baseRate = bound (baseRate, WAD, vault.RATE_CEILING());
        vault.setParameter("baseRate", baseRate);
        trackCallEnd(msg.sig);
    }

    // Oracle updates the collateral spot price
    function changeSpotPrice(uint256 price) public {
        trackCallStart(msg.sig);

        price = bound(price, minSpotPrice, maxSpotPrice);
        testContract.setOraclePrice(price);

        trackCallEnd(msg.sig);
    }

    /// ======== Helper Functions ======== ///

    function getRateAccumulator() view public returns (uint64) {
        return uint64(uint256(
            getGhostValue(
                keccak256(abi.encode(RATE_ACCUMULATOR))
            )
        ));
    }

    function getPreviousRateAccumulator() view public returns (uint64) {
        bytes32 prevValueKey = keccak256("prevRateAccumulator");
        return uint64(uint256(getGhostValue(prevValueKey)));
    }

    // Track the current and previous rate accumulator
    function _trackRateAccumulator() private {
        InterestRateModel.IRS memory irs = vault.getIRS();
        trackValue(RATE_ACCUMULATOR, bytes32(uint256(irs.rateAccumulator)));
    }

    // Track the rateAcummulator and the previous rate accumulator for a given user 
    function _trackUserRateAccumulator(address user) private {
        InterestRateModel.IRS memory irs = vault.getIRS();
        bytes32 key = getValueKey(user, RATE_ACCUMULATOR);
        trackValue(key, bytes32(uint256(irs.rateAccumulator)));
    }

    function _setupPermissions(address owner, address creditor) internal {
        vm.startPrank(creditor);
        vault.modifyPermission(owner, true);
        cdm.modifyPermission(address(vault), true);
        vm.stopPrank();
    }
}