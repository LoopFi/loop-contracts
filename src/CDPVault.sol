// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICDPVaultBase, CDPVaultConstants, CDPVaultConfig} from "./interfaces/ICDPVault.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import {WAD, toInt256, toUint64, max, min, add, sub, wmul, wdiv, wmulUp, abs} from "./utils/Math.sol";
import {Permission} from "./utils/Permission.sol";
import {Pause, PAUSER_ROLE} from "./utils/Pause.sol";
import {IPoolV3} from "./interfaces/IPoolV3.sol";

import {IChefIncentivesController} from "./reward/interfaces/IChefIncentivesController.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CreditLogic} from "@gearbox-protocol/core-v3/contracts/libraries/CreditLogic.sol";
import {QuotasLogic} from "@gearbox-protocol/core-v3/contracts/libraries/QuotasLogic.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";

interface IPoolV3Loop is IPoolV3 {
    function mintProfit(uint256 profit) external;

    function enter(address user, uint256 amount) external;

    function exit(address user, uint256 amount) external;

    function addAvailable(address user, int256 amount) external;
}

interface IRewardManager {
    function handleRewardsOnDeposit(address user, uint256 amount, int256 deltaCollateral) external;

    function handleRewardsOnWithdraw(
        address user,
        uint256 amount,
        int256 deltaCollateral
    ) external returns (address[] memory, uint256[] memory, address to);
}

// Authenticated Roles
bytes32 constant VAULT_CONFIG_ROLE = keccak256("VAULT_CONFIG_ROLE");
bytes32 constant VAULT_UNWINDER_ROLE = keccak256("VAULT_UNWINDER_ROLE");

/// @title CDPVault
/// @notice Base logic of a borrow vault for depositing collateral and drawing credit against it
/// @dev All accrued interests is taken by the protocol as profit to be distributed to LP stakers, dLP stakers and the DAO
contract CDPVault is AccessControl, Pause, Permission, ICDPVaultBase {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;
    using SafeCast for int256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // CDPVault Parameters
    /// @notice Oracle of the collateral token
    IOracle public immutable oracle;
    /// @notice collateral token
    IERC20 public immutable token;
    /// @notice Collateral token's decimals scale (10 ** decimals)
    uint256 public immutable tokenScale;

    uint256 constant INDEX_PRECISION = 10 ** 9;

    //uint16 constant PERCENTAGE_FACTOR = 1e4; //percentage plus two decimals

    IPoolV3 public immutable pool;
    IERC20 public immutable poolUnderlying;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct VaultConfig {
        /// @notice Min. amount of debt that has to be generated by a position [wad]
        uint128 debtFloor;
        /// @notice Collateralization ratio below which a position can be liquidated [wad]
        uint64 liquidationRatio;
    }

    /// @notice CDPVault configuration
    VaultConfig public vaultConfig;

    // CDPVault Accounting
    /// @notice Sum of backed debt over all positions [wad]
    uint256 public totalDebt;

    struct DebtData {
        uint256 debt;
        uint256 cumulativeIndexNow;
        uint256 cumulativeIndexLastUpdate;
        uint128 cumulativeQuotaInterest;
        uint192 cumulativeQuotaIndexNow;
        uint192 cumulativeQuotaIndexLU;
        uint256 accruedInterest;
        //   uint256 accruedFees;
    }

    // Position Accounting
    struct Position {
        uint256 collateral; // [wad]
        uint256 debt; // [wad]
        uint256 lastDebtUpdate; // [timestamp]
        uint256 cumulativeIndexLastUpdate;
        uint192 cumulativeQuotaIndexLU;
        uint128 cumulativeQuotaInterest;
    }

    /// @notice Map of user positions
    mapping(address => Position) public positions;

    struct LiquidationConfig {
        /// @notice Penalty applied during liquidation [wad]
        uint64 liquidationPenalty;
        /// @notice Discount on collateral during liquidation [wad]
        uint64 liquidationDiscount;
    }

    /// @notice Liquidation configuration
    LiquidationConfig public liquidationConfig;

    /// @notice Reward incentives controller
    IChefIncentivesController public rewardController;

    /// @notice Reward manager
    IRewardManager public rewardManager;
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ModifyPosition(address indexed position, uint256 debt, uint256 collateral, uint256 totalDebt);
    event ModifyCollateralAndDebt(
        address indexed position,
        address indexed collateralizer,
        address indexed creditor,
        int256 deltaCollateral,
        int256 deltaDebt
    );
    event SetParameter(bytes32 indexed parameter, uint256 data);
    event SetParameter(bytes32 indexed parameter, address data);
    event LiquidatePosition(
        address indexed position,
        uint256 collateralReleased,
        uint256 normalDebtRepaid,
        address indexed liquidator
    );
    event VaultCreated(address indexed vault, address indexed token, address indexed owner);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDPVault__modifyPosition_debtFloor();
    error CDPVault__modifyCollateralAndDebt_notSafe();
    error CDPVault__modifyCollateralAndDebt_noPermission();
    error CDPVault__modifyCollateralAndDebt_maxUtilizationRatio();
    error CDPVault__setParameter_unrecognizedParameter();
    error CDPVault__liquidatePosition_notUnsafe();
    error CDPVault__liquidatePosition_invalidSpotPrice();
    error CDPVault__liquidatePosition_invalidParameters();
    error CDPVault__noBadDebt();
    error CDPVault__BadDebt();
    error CDPVault__repayAmountNotEnough();
    error CDPVault__tooHighRepayAmount();
    error CDPVault__recoverERC20_invalidToken();
    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(CDPVaultConstants memory constants, CDPVaultConfig memory config) {
        pool = constants.pool;
        oracle = constants.oracle;
        token = constants.token;
        tokenScale = constants.tokenScale;

        poolUnderlying = IERC20(pool.underlyingToken());

        vaultConfig = VaultConfig({debtFloor: config.debtFloor, liquidationRatio: config.liquidationRatio});

        liquidationConfig = LiquidationConfig({
            liquidationPenalty: config.liquidationPenalty,
            liquidationDiscount: config.liquidationDiscount
        });

        // Access Control Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, config.roleAdmin);
        _grantRole(VAULT_CONFIG_ROLE, config.vaultAdmin);
        _grantRole(PAUSER_ROLE, config.pauseAdmin);

        emit VaultCreated(address(this), address(token), config.roleAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param parameter Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParameter(bytes32 parameter, uint256 data) external whenNotPaused onlyRole(VAULT_CONFIG_ROLE) {
        if (parameter == "debtFloor") vaultConfig.debtFloor = uint128(data);
        else if (parameter == "liquidationRatio") vaultConfig.liquidationRatio = uint64(data);
        else if (parameter == "liquidationPenalty") liquidationConfig.liquidationPenalty = uint64(data);
        else if (parameter == "liquidationDiscount") liquidationConfig.liquidationDiscount = uint64(data);
        else revert CDPVault__setParameter_unrecognizedParameter();
        emit SetParameter(parameter, data);
    }

    /// @notice Sets various address parameters for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param parameter Name of the variable to set
    /// @param data New address to set for the variable
    function setParameter(bytes32 parameter, address data) external whenNotPaused onlyRole(VAULT_CONFIG_ROLE) {
        if (parameter == "rewardController") rewardController = IChefIncentivesController(data);
        else if (parameter == "rewardManager") rewardManager = IRewardManager(data);
        else revert CDPVault__setParameter_unrecognizedParameter();
        emit SetParameter(parameter, data);
    }

    /*//////////////////////////////////////////////////////////////
                      COLLATERAL BALANCE ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits collateral tokens into this contract and increases a user's collateral balance
    /// @dev The caller needs to approve this contract to transfer tokens on their behalf
    /// @param to Address of the user to attribute the collateral to
    /// @param amount Amount of tokens to deposit [tokenScale]
    /// @return tokenAmount Amount of collateral deposited [wad]
    function deposit(address to, uint256 amount) external returns (uint256 tokenAmount) {
        tokenAmount = wdiv(amount, tokenScale);
        int256 deltaCollateral = toInt256(tokenAmount);
        modifyCollateralAndDebt({
            owner: to,
            collateralizer: msg.sender,
            creditor: msg.sender,
            deltaCollateral: deltaCollateral,
            deltaDebt: 0
        });
    }

    /// @notice Withdraws collateral tokens from this contract and decreases a user's collateral balance
    /// @param to Address of the user to withdraw tokens to
    /// @param amount Amount of tokens to withdraw [tokenScale]
    /// @return tokenAmount Amount of tokens withdrawn [wad]
    function withdraw(address to, uint256 amount) external returns (uint256 tokenAmount) {
        tokenAmount = wdiv(amount, tokenScale);
        int256 deltaCollateral = -toInt256(tokenAmount);
        modifyCollateralAndDebt({
            owner: to,
            collateralizer: msg.sender,
            creditor: msg.sender,
            deltaCollateral: deltaCollateral,
            deltaDebt: 0
        });
    }

    /// @notice Borrows credit against collateral
    /// @param borrower Address of the borrower
    /// @param position Address of the position
    /// @param amount Amount of debt to generate [wad]
    /// @dev The borrower will receive the amount of credit in the underlying token
    function borrow(address borrower, address position, uint256 amount) external {
        int256 deltaDebt = toInt256(amount);
        modifyCollateralAndDebt({
            owner: position,
            collateralizer: position,
            creditor: borrower,
            deltaCollateral: 0,
            deltaDebt: deltaDebt
        });
    }

    /// @notice Repays credit against collateral
    /// @param borrower Address of the borrower
    /// @param position Address of the position
    /// @param amount Amount of debt to repay [wad]
    /// @dev The borrower will repay the amount of credit in the underlying token
    function repay(address borrower, address position, uint256 amount) external {
        int256 deltaDebt = -toInt256(amount);
        modifyCollateralAndDebt({
            owner: position,
            collateralizer: position,
            creditor: borrower,
            deltaCollateral: 0,
            deltaDebt: deltaDebt
        });
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current spot price of the collateral token
    /// @return _ Current spot price of the collateral token [wad]
    function spotPrice() public view returns (uint256) {
        return oracle.spot(address(token));
    }

    function _handleTokenRewards(address owner, uint256 collateralAmountBefore, int256 deltaCollateral) internal {
        if (deltaCollateral > 0) {
            rewardManager.handleRewardsOnDeposit(owner, collateralAmountBefore, deltaCollateral);
        } else if (deltaCollateral < 0) {
            (address[] memory tokens, uint256[] memory rewardAmounts, address to) = rewardManager
                .handleRewardsOnWithdraw(owner, collateralAmountBefore, deltaCollateral);

            for (uint256 i = 0; i < tokens.length; i++) {
                if (rewardAmounts[i] != 0) {
                    IERC20(tokens[i]).safeTransfer(to, rewardAmounts[i]);
                }
            }
        }
    }

    function getRewards(address owner) external {
        if (address(rewardManager) != address(0)) {
            (address[] memory tokens, uint256[] memory rewardAmounts, address to) = rewardManager
                .handleRewardsOnWithdraw(owner, positions[owner].collateral, 0);

            for (uint256 i = 0; i < tokens.length; i++) {
                if (rewardAmounts[i] != 0) {
                    IERC20(tokens[i]).safeTransfer(to, rewardAmounts[i]);
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates a position's collateral and debt balances
    /// @dev This is the only method which is allowed to modify a position's collateral and debt balances
    /// @param owner Address of the owner of the position
    /// @param position Position state
    /// @param newDebt New debt balance [wad]
    /// @param newCumulativeIndex New cumulative index
    /// @param deltaCollateral Amount of collateral to put up (+) or to remove (-) from the position [wad]
    /// @param totalDebt_ Total debt of the vault [wad]
    function _modifyPosition(
        address owner,
        Position memory position,
        uint256 newDebt,
        uint256 newCumulativeIndex,
        int256 deltaCollateral,
        uint256 totalDebt_
    ) internal returns (Position memory) {
        uint256 currentDebt = position.debt;
        uint256 collateralBefore = position.collateral;

        // update collateral and debt amounts by the deltas
        position.collateral = add(position.collateral, deltaCollateral);
        position.debt = newDebt; // U:[CM-10,11]
        position.cumulativeIndexLastUpdate = newCumulativeIndex; // U:[CM-10,11]
        position.lastDebtUpdate = uint64(block.number); // U:[CM-10,11]

        // position either has no debt or more debt than the debt floor
        if (position.debt != 0 && position.debt < uint256(vaultConfig.debtFloor))
            revert CDPVault__modifyPosition_debtFloor();

        // store the position's balances
        positions[owner] = position;

        // update the global debt balance
        if (newDebt > currentDebt) {
            totalDebt_ = totalDebt_ + (newDebt - currentDebt);
        } else {
            totalDebt_ = totalDebt_ - (currentDebt - newDebt);
        }
        totalDebt = totalDebt_;

        if (address(rewardController) != address(0)) {
            rewardController.handleActionAfter(owner, position.debt, totalDebt_);
        }

        if (address(rewardManager) != address(0)) _handleTokenRewards(owner, collateralBefore, deltaCollateral);

        emit ModifyPosition(owner, position.debt, position.collateral, totalDebt_);

        return position;
    }

    /// @notice Returns true if the collateral value is equal or greater than the debt
    function _isCollateralized(
        uint256 debt,
        uint256 collateralValue,
        uint256 liquidationRatio
    ) internal pure returns (bool) {
        return (wdiv(collateralValue, liquidationRatio) >= debt);
    }

    /// @notice Modifies a Position's collateral and debt balances
    /// @dev Checks that the global debt ceiling and the vault's debt ceiling have not been exceeded via the CDM,
    /// - that the Position is still safe after the modification,
    /// - that the msg.sender has the permission of the owner to decrease the collateral-to-debt ratio,
    /// - that the msg.sender has the permission of the collateralizer to put up new collateral,
    /// - that the msg.sender has the permission of the creditor to settle debt with their credit,
    /// - that that the vault debt floor is exceeded
    /// - that the vault minimum collateralization ratio is met
    /// @param owner Address of the owner of the position
    /// @param collateralizer Address of who puts up or receives the collateral delta
    /// @param creditor Address of who provides or receives the credit delta for the debt delta
    /// @param deltaCollateral Amount of collateral to put up (+) or to remove (-) from the position [wad]
    /// @param deltaDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// to settle (-) on this position [wad]
    function modifyCollateralAndDebt(
        address owner,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaDebt
    ) public {
        if (
            // position is either more safe than before or msg.sender has the permission from the owner
            ((deltaDebt > 0 || deltaCollateral < 0) && !hasPermission(owner, msg.sender)) ||
            // msg.sender has the permission of the collateralizer to collateralize the position using their cash
            (deltaCollateral > 0 && !hasPermission(collateralizer, msg.sender)) ||
            // msg.sender has the permission of the creditor to use their credit to repay the debt
            (deltaDebt < 0 && !hasPermission(creditor, msg.sender))
        ) revert CDPVault__modifyCollateralAndDebt_noPermission();

        // if the vault is paused allow only debt decreases
        if (deltaDebt > 0 || deltaCollateral != 0){
            _requireNotPaused();
        }

        Position memory position = positions[owner];
        DebtData memory debtData = _calcDebt(position);

        uint256 newDebt;
        uint256 newCumulativeIndex;

        uint256 profit;
        int256 quotaRevenueChange;
        if (deltaDebt > 0) {
            (newDebt, newCumulativeIndex) = CreditLogic.calcIncrease(
                uint256(deltaDebt), // delta debt
                position.debt,
                debtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                position.cumulativeIndexLastUpdate
            ); // U:[CM-10]
            position.cumulativeQuotaInterest = debtData.cumulativeQuotaInterest;
            position.cumulativeQuotaIndexLU = debtData.cumulativeQuotaIndexNow;
            quotaRevenueChange = _calcQuotaRevenueChange(deltaDebt);
            pool.lendCreditAccount(uint256(deltaDebt), creditor); // F:[CM-20]
        } else if (deltaDebt < 0) {
            uint256 maxRepayment = calcTotalDebt(debtData);
            uint256 amount = abs(deltaDebt);
            if (amount >= maxRepayment) {
                amount = maxRepayment; // U:[CM-11]
                deltaDebt = -toInt256(maxRepayment);
            }

            poolUnderlying.safeTransferFrom(creditor, address(pool), amount);

            uint128 newCumulativeQuotaInterest;
            if (amount == maxRepayment) {
                newDebt = 0;
                newCumulativeIndex = debtData.cumulativeIndexNow;
                profit = debtData.accruedInterest;
                newCumulativeQuotaInterest = 0;
            } else {
                (newDebt, newCumulativeIndex, profit, newCumulativeQuotaInterest) = calcDecrease(
                    amount, // delta debt
                    position.debt,
                    debtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                    position.cumulativeIndexLastUpdate,
                    debtData.cumulativeQuotaInterest
                );
            }
            quotaRevenueChange = _calcQuotaRevenueChange(-int(debtData.debt - newDebt));
            pool.repayCreditAccount(debtData.debt - newDebt, profit, 0); // U:[CM-11]

            position.cumulativeQuotaInterest = newCumulativeQuotaInterest;
            position.cumulativeQuotaIndexLU = debtData.cumulativeQuotaIndexNow;
        } else {
            newDebt = position.debt;
            newCumulativeIndex = debtData.cumulativeIndexLastUpdate;
        }

        if (deltaCollateral > 0) {
            uint256 amount = wmul(deltaCollateral.toUint256(), tokenScale);
            token.safeTransferFrom(collateralizer, address(this), amount);
        } else if (deltaCollateral < 0) {
            uint256 amount = wmul(abs(deltaCollateral), tokenScale);
            token.safeTransfer(collateralizer, amount);
        }

        position = _modifyPosition(owner, position, newDebt, newCumulativeIndex, deltaCollateral, totalDebt);

        VaultConfig memory config = vaultConfig;
        uint256 spotPrice_ = spotPrice();
        uint256 collateralValue = wmul(position.collateral, spotPrice_);

        if (
            (deltaDebt > 0 || deltaCollateral < 0) &&
            !_isCollateralized(calcTotalDebt(_calcDebt(position)), collateralValue, config.liquidationRatio)
        ) revert CDPVault__modifyCollateralAndDebt_notSafe();

        if (quotaRevenueChange != 0) {
            IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange); // U:[PQK-15]
        }
        emit ModifyCollateralAndDebt(owner, collateralizer, creditor, deltaCollateral, deltaDebt);
    }

    function _calcQuotaRevenueChange(int256 deltaDebt) internal view returns (int256 quotaRevenueChange) {
        uint16 rate = IPoolQuotaKeeperV3(poolQuotaKeeper()).getQuotaRate(address(token));
        return QuotasLogic.calcQuotaRevenueChange(rate, deltaDebt);
    }

    function _calcDebt(Position memory position) internal view returns (DebtData memory cdd) {
        uint256 index = pool.baseInterestIndex();
        cdd.debt = position.debt;
        cdd.cumulativeIndexNow = index;
        cdd.cumulativeIndexLastUpdate = position.cumulativeIndexLastUpdate;
        cdd.cumulativeQuotaIndexLU = position.cumulativeQuotaIndexLU;
        // Get cumulative quota interest
        (cdd.cumulativeQuotaInterest, cdd.cumulativeQuotaIndexNow) = _getQuotedTokensData(cdd);

        cdd.cumulativeQuotaInterest += position.cumulativeQuotaInterest;

        cdd.accruedInterest = CreditLogic.calcAccruedInterest(cdd.debt, cdd.cumulativeIndexLastUpdate, index);

        cdd.accruedInterest += cdd.cumulativeQuotaInterest;
    }

    /// @dev Returns quotas data for credit manager and credit account
    function _getQuotedTokensData(
        DebtData memory cdd
    ) internal view returns (uint128 outstandingQuotaInterest, uint192 cumulativeQuotaIndexNow) {
        cumulativeQuotaIndexNow = IPoolQuotaKeeperV3(poolQuotaKeeper()).cumulativeIndex(address(token));
        uint128 outstandingInterestDelta = QuotasLogic.calcAccruedQuotaInterest(
            uint96(cdd.debt),
            cumulativeQuotaIndexNow,
            cdd.cumulativeQuotaIndexLU
        );

        outstandingQuotaInterest = outstandingInterestDelta; // U:[CM-24]
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidates a single unsafe position by selling collateral at a discounted (`liquidationDiscount`)
    /// oracle price. The liquidator has to provide the amount he wants to repay or sell (`repayAmounts`) for
    /// the position. From that repay amount a penalty (`liquidationPenalty`) is subtracted to mitigate against
    /// profitable self liquidations. If the available collateral of a position is not sufficient to cover the debt
    /// the vault accumulates 'bad debt'.
    /// @dev The liquidator has to approve the vault to transfer the sum of `repayAmounts`.
    /// @param owner Owner of the position to liquidate
    /// @param repayAmount Amount the liquidator wants to repay [wad]
    function liquidatePosition(address owner, uint256 repayAmount) external whenNotPaused {
        // validate params
        if (owner == address(0) || repayAmount == 0) revert CDPVault__liquidatePosition_invalidParameters();

        // load configs
        VaultConfig memory config = vaultConfig;
        LiquidationConfig memory liqConfig_ = liquidationConfig;

        // load liquidated position
        Position memory position = positions[owner];
        DebtData memory debtData = _calcDebt(position);

        // load price and calculate discounted price
        uint256 spotPrice_ = spotPrice();
        uint256 discountedPrice = wmul(spotPrice_, liqConfig_.liquidationDiscount);
        if (spotPrice_ == 0) revert CDPVault__liquidatePosition_invalidSpotPrice();
        
        // Ensure that there's no bad debt
        if (calcTotalDebt(debtData) > wmul(position.collateral, spotPrice_)) revert CDPVault__BadDebt();

        // compute collateral to take, debt to repay and penalty to pay
        uint256 takeCollateral = wdiv(repayAmount, discountedPrice);
        uint256 deltaDebt = wmul(repayAmount, liqConfig_.liquidationPenalty);
        uint256 penalty = wmul(repayAmount, WAD - liqConfig_.liquidationPenalty);
        if (takeCollateral > position.collateral) revert CDPVault__tooHighRepayAmount();

        // verify that the position is indeed unsafe
        if (_isCollateralized(calcTotalDebt(debtData), wmul(position.collateral, spotPrice_), config.liquidationRatio))
            revert CDPVault__liquidatePosition_notUnsafe();

        // transfer the repay amount from the liquidator to the vault
        poolUnderlying.safeTransferFrom(msg.sender, address(pool), repayAmount - penalty);

        uint256 newDebt;
        uint256 profit;
        uint256 maxRepayment = calcTotalDebt(debtData);
        uint256 newCumulativeIndex;
        if (deltaDebt == maxRepayment) {
            newDebt = 0;
            newCumulativeIndex = debtData.cumulativeIndexNow;
            profit = debtData.accruedInterest;
            position.cumulativeQuotaInterest = 0;
        } else {
            (newDebt, newCumulativeIndex, profit, position.cumulativeQuotaInterest) = calcDecrease(
                deltaDebt, // delta debt
                debtData.debt,
                debtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                debtData.cumulativeIndexLastUpdate,
                debtData.cumulativeQuotaInterest
            );
        }
        position.cumulativeQuotaIndexLU = debtData.cumulativeQuotaIndexNow;
        // update liquidated position
        position = _modifyPosition(owner, position, newDebt, newCumulativeIndex, -toInt256(takeCollateral), totalDebt);

        pool.repayCreditAccount(debtData.debt - newDebt, profit, 0); // U:[CM-11]
        // transfer the collateral amount from the vault to the liquidator
        token.safeTransfer(msg.sender, takeCollateral);

        // Mint the penalty from the vault to the treasury
        poolUnderlying.safeTransferFrom(msg.sender, address(pool), penalty);
        IPoolV3Loop(address(pool)).mintProfit(penalty);

        if (debtData.debt - newDebt != 0) {
            IPoolV3(pool).updateQuotaRevenue(_calcQuotaRevenueChange(-int(debtData.debt - newDebt))); // U:[PQK-15]
        }
    }

    /// @dev The liquidator has to approve the vault to transfer the sum of `repayAmounts`.
    /// @param owner Owner of the position to liquidate
    /// @param repayAmount Amount the liquidator wants to repay [wad]
    function liquidatePositionBadDebt(address owner, uint256 repayAmount) external whenNotPaused {
        // validate params
        if (owner == address(0) || repayAmount == 0) revert CDPVault__liquidatePosition_invalidParameters();

        // load configs
        VaultConfig memory config = vaultConfig;
        LiquidationConfig memory liqConfig_ = liquidationConfig;

        // load liquidated position
        Position memory position = positions[owner];
        DebtData memory debtData = _calcDebt(position);
        uint256 spotPrice_ = spotPrice();
        if (spotPrice_ == 0) revert CDPVault__liquidatePosition_invalidSpotPrice();
        // verify that the position is indeed unsafe
        if (_isCollateralized(calcTotalDebt(debtData), wmul(position.collateral, spotPrice_), config.liquidationRatio))
            revert CDPVault__liquidatePosition_notUnsafe();

        // load price and calculate discounted price
        uint256 discountedPrice = wmul(spotPrice_, liqConfig_.liquidationDiscount);
        // Enusure that the debt is greater than the collateral at discounted price
        if (calcTotalDebt(debtData) <= wmul(position.collateral, discountedPrice)) revert CDPVault__noBadDebt();
        // compute collateral to take, debt to repay
        uint256 takeCollateral = wdiv(repayAmount, discountedPrice);
        if (takeCollateral < position.collateral) revert CDPVault__repayAmountNotEnough();

        // account for bad debt
        takeCollateral = position.collateral;
        repayAmount = wmul(takeCollateral, discountedPrice);
        uint256 loss = calcTotalDebt(debtData) - repayAmount;

        // transfer the repay amount from the liquidator to the vault
        poolUnderlying.safeTransferFrom(msg.sender, address(pool), repayAmount);

        position.cumulativeQuotaInterest = 0;
        position.cumulativeQuotaIndexLU = debtData.cumulativeQuotaIndexNow;
        // update liquidated position
        position = _modifyPosition(
            owner,
            position,
            0,
            debtData.cumulativeIndexNow,
            -toInt256(takeCollateral),
            totalDebt
        );

        pool.repayCreditAccount(debtData.debt, 0, loss); // U:[CM-11]
        // transfer the collateral amount from the vault to the liquidator
        token.safeTransfer(msg.sender, takeCollateral);

        int256 quotaRevenueChange = _calcQuotaRevenueChange(-int(debtData.debt));
        if (quotaRevenueChange != 0) {
            IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange); // U:[PQK-15]
        }
    }

    /// @dev Computes new debt principal and interest index (and other values) after decreasing debt
    ///      - Debt comprises of multiple components which are repaid in the following order:
    ///        quota update fees => quota interest => base interest => debt principal.
    ///        New values for all these components depend on what portion of each was repaid.
    ///      - Debt principal, for example, only decreases if all previous components were fully repaid
    ///      - The new credit account's interest index stays the same if base interest was not repaid at all,
    ///        is set to the current interest index if base interest was repaid fully, and is a solution to
    ///        the equation `debt * (indexNow / indexLastUpdate - 1) - delta = debt * (indexNow / indexNew - 1)`
    ///        when only `delta` of accrued interest was repaid
    /// @param amount Amount of debt to repay
    /// @param debt Debt principal before repayment
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @return newDebt Debt principal after repayment
    /// @return newCumulativeIndex Credit account's quota interest after repayment
    /// @return profit Amount of underlying tokens received as fees by the DAO
    /// @return newCumulativeQuotaInterest Credit account's accrued quota interest after repayment
    // @return newQuotaFees Amount of unpaid quota fees left after repayment
    function calcDecrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate,
        uint128 cumulativeQuotaInterest
    )
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex, uint256 profit, uint128 newCumulativeQuotaInterest)
    {
        uint256 amountToRepay = amount;

        if (cumulativeQuotaInterest != 0 && amountToRepay != 0) {
            // All interest accrued on the quota interest is taken by the DAO to be distributed to LP stakers, dLP stakers and the DAO

            if (amountToRepay >= cumulativeQuotaInterest) {
                amountToRepay -= cumulativeQuotaInterest; // U:[CL-3]
                profit += cumulativeQuotaInterest; // U:[CL-3]

                newCumulativeQuotaInterest = 0; // U:[CL-3]
            } else {
                // If amount is not enough to repay quota interest + DAO fee, then send all to the stakers
                uint256 quotaInterestPaid = amountToRepay; // U:[CL-3]
                profit += amountToRepay; // U:[CL-3]
                amountToRepay = 0; // U:[CL-3]

                newCumulativeQuotaInterest = uint128(cumulativeQuotaInterest - quotaInterestPaid); // U:[CL-3]
            }
        } else {
            newCumulativeQuotaInterest = cumulativeQuotaInterest;
        }

        if (amountToRepay != 0) {
            uint256 interestAccrued = CreditLogic.calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
                cumulativeIndexNow: cumulativeIndexNow
            });
            // All interest accrued on the base interest is taken by the DAO to be distributed to LP stakers, dLP stakers and the DAO
            if (amountToRepay >= interestAccrued) {
                amountToRepay -= interestAccrued;

                profit += interestAccrued;

                newCumulativeIndex = cumulativeIndexNow;
            } else {
                // If amount is not enough to repay interest, then send all to the stakers and update index
                profit += amountToRepay; // U:[CL-3]
                amountToRepay = 0; // U:[CL-3]

                newCumulativeIndex =
                    (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate) /
                    (INDEX_PRECISION *
                        cumulativeIndexNow -
                        (INDEX_PRECISION * profit * cumulativeIndexLastUpdate) /
                        debt); // U:[CL-3]
            }
        } else {
            newCumulativeIndex = cumulativeIndexLastUpdate;
        }
        newDebt = debt - amountToRepay;
    }

    /// @dev Computes interest accrued since the last update
    function calcAccruedInterest(
        uint256 amount,
        uint256 cumulativeIndexLastUpdate,
        uint256 cumulativeIndexNow
    ) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return (amount * cumulativeIndexNow) / cumulativeIndexLastUpdate - amount;
    }

    /// @notice Returns the total debt of a position
    /// @param position Address of the position
    /// @return totalDebt Total debt of the position [wad]
    function virtualDebt(address position) external view returns (uint256) {
        return calcTotalDebt(_calcDebt(positions[position]));
    }

    /// @dev Computes total debt, given raw debt data
    /// @param debtData See `DebtData` (must have debt data filled)
    function calcTotalDebt(DebtData memory debtData) internal pure returns (uint256) {
        return debtData.debt + debtData.accruedInterest; //+ debtData.accruedFees;
    }

    /// @notice Returns address of the quota keeper connected to the pool
    function poolQuotaKeeper() public view returns (address) {
        return IPoolV3(pool).poolQuotaKeeper(); // U:[CM-47]
    }

    /// @notice Returns quotas interest
    function quotasInterest(address position) external view returns (uint256) {
        DebtData memory debtData = _calcDebt(positions[position]);
        return debtData.cumulativeQuotaInterest;
    }

    /// @notice Returns debt data for a position
    function getDebtData(address position) external view returns (DebtData memory) {
        return _calcDebt(positions[position]);
    }

    /// @notice Returns debt data for a position
    function getDebtInfo(
        address position
    ) external view returns (uint256 debt, uint256 accruedInterest, uint256 cumulativeQuotaInterest) {
        DebtData memory debtData = _calcDebt(positions[position]);
        return (debtData.debt, debtData.accruedInterest, debtData.cumulativeQuotaInterest);
    }

    /*//////////////////////////////////////////////////////////////
                              RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Recovers ERC20 tokens from the vault
    /// @param tokenAddress Address of the token to recover
    /// @param to Address to recover the token to
    /// @param tokenAmount Amount of the token to recover
    /// @dev The token to recover cannot be the same as the collateral token
    function recoverERC20(address tokenAddress, address to, uint256 tokenAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tokenAddress == address(token)) revert CDPVault__recoverERC20_invalidToken();
        IERC20(tokenAddress).safeTransfer(to, tokenAmount);
    }
}
