// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBuffer} from "./interfaces/IBuffer.sol";
import {ICDM} from "./interfaces/ICDM.sol";
import {ICDPVaultBase, CDPVaultConstants, CDPVaultConfig} from "./interfaces/ICDPVault.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import {WAD, toInt256, toUint64, max, min, add, sub, wmul, wdiv, wmulUp, abs} from "./utils/Math.sol";
import {Permission} from "./utils/Permission.sol";
import {Pause, PAUSER_ROLE} from "./utils/Pause.sol";

import {getCredit, getDebt, getCreditLine} from "./CDM.sol";
import {InterestRateModel} from "./InterestRateModel.sol";

import {IChefIncentivesController} from "./reward/interfaces/IChefIncentivesController.sol";
import {IPoolV3} from "lib/core-v3/contracts/interfaces/IPoolV3.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IPoolV3Loop is IPoolV3 {
    function mintProfit(uint256 profit) external;

    function enter(address user, uint256 amount) external;

    function exit(address user, uint256 amount) external;

    function addAvailable(address user, int256 amount) external;
}
// Authenticated Roles
bytes32 constant VAULT_CONFIG_ROLE = keccak256("VAULT_CONFIG_ROLE");
bytes32 constant VAULT_UNWINDER_ROLE = keccak256("VAULT_UNWINDER_ROLE");

/// @notice Calculates the actual debt from a normalized debt amount
/// @param normalDebt Normalized debt (either of a position or the total normalized debt)
/// @param rateAccumulator Rate accumulator
/// @return debt Actual debt [wad]
function calculateDebt(
    uint256 normalDebt,
    uint64 rateAccumulator
) pure returns (uint256 debt) {
    debt = wmul(normalDebt, rateAccumulator);
}

/// @notice Calculates the normalized debt from an actual debt amount
/// @param debt Actual debt (either of a position or the total debt)
/// @param rateAccumulator Rate accumulator
/// @return normalDebt Normalized debt [wad]
function calculateNormalDebt(
    uint256 debt,
    uint64 rateAccumulator
) pure returns (uint256 normalDebt) {
    normalDebt = wdiv(debt, rateAccumulator);

    // account for rounding errors due to division
    if (calculateDebt(normalDebt, rateAccumulator) < debt) {
        unchecked {
            ++normalDebt;
        }
    }
}

/// @title CDPVault
/// @notice Base logic of a borrow vault for depositing collateral and drawing credit against it
contract CDPVault is
    AccessControl,
    Pause,
    Permission,
    InterestRateModel,
    ICDPVaultBase
{
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;
    using SafeCast for int256;
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // CDPVault Parameters
    /// @notice CDM (Credit and Debt Manager)
    ICDM public immutable cdm;
    /// @notice Oracle of the collateral token
    IOracle public immutable oracle;
    /// @notice Global surplus and debt Buffer
    IBuffer public immutable buffer;
    /// @notice collateral token
    IERC20 public immutable token;
    /// @notice Collateral token's decimals scale (10 ** decimals)
    uint256 public immutable tokenScale;

    uint256 constant INDEX_PRECISION = 10 ** 9;

    /// @dev Percentage of accrued interest in bps taken by the protocol as profit
    uint16 internal feeInterest;

    uint16 constant PERCENTAGE_FACTOR = 1e4; //percentage plus two decimals

    address public pool;
    IERC20 public poolUnderlying;
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
    /// @notice Sum of backed normalized debt over all positions [wad]
    uint256 public totalNormalDebt;

    struct CollateralDebtData {
        uint256 debt;
        uint256 cumulativeIndexNow;
        uint256 cumulativeIndexLastUpdate;
        uint256 accruedInterest;
        uint256 accruedFees;
    }

    // Position Accounting
    struct Position {
        uint256 collateral; // [wad]
        uint256 debt; // [wad]
        uint256 lastDebtUpdate; // [timestamp]
        uint256 cumulativeIndexLastUpdate;
    }
    /// @notice Map of user positions
    mapping(address owner => Position) public positions;

    struct LiquidationConfig {
        // is subtracted from the `repayAmount` to avoid profitable self liquidations [wad]
        // defined as: 1 - penalty (e.g. `liquidationPenalty` = 0.95 is a 5% penalty)
        uint64 liquidationPenalty;
        // is subtracted from the `spotPrice` of the collateral to provide incentive to liquidate unsafe positions [wad]
        // defined as: 1 - discount (e.g. `liquidationDiscount` = 0.95 is a 5% discount)
        uint64 liquidationDiscount;
    }
    /// @notice Liquidation configuration
    LiquidationConfig public liquidationConfig;

    /// @notice Reward incentives controller
    IChefIncentivesController public rewardController;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ModifyPosition(
        address indexed position,
        uint256 debt,
        uint256 collateral,
        uint256 totalNormalDebt
    );
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
    event VaultCreated(
        address indexed vault,
        address indexed token,
        address indexed owner
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CDPVault__modifyPosition_debtFloor();
    error CDPVault__modifyCollateralAndDebt_notSafe();
    error CDPVault__modifyCollateralAndDebt_noPermission();
    error CDPVault__modifyCollateralAndDebt_maxUtilizationRatio();
    error CDPVault__setParameter_unrecognizedParameter();
    error CDPVault__liquidatePosition_notUnsafe();
    error CDPVault__liquidatePosition_invalidParameters();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(
        CDPVaultConstants memory constants,
        CDPVaultConfig memory config
    ) {
        cdm = constants.cdm;
        oracle = constants.oracle;
        buffer = constants.buffer;
        token = constants.token;
        tokenScale = constants.tokenScale;

        vaultConfig = VaultConfig({
            debtFloor: config.debtFloor,
            liquidationRatio: config.liquidationRatio
        });

        liquidationConfig = LiquidationConfig({
            liquidationPenalty: config.liquidationPenalty,
            liquidationDiscount: config.liquidationDiscount
        });

        // _setIRS(
        //     IRS({
        //         baseRate: toUint64(config.baseRate),
        //         lastUpdated: toUint64(block.timestamp),
        //         rateAccumulator: toUint64(WAD)
        //     })
        // );

        // Access Control Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, config.roleAdmin);
        _grantRole(VAULT_CONFIG_ROLE, config.vaultAdmin);
        _grantRole(PAUSER_ROLE, config.pauseAdmin);
        _grantRole(VAULT_UNWINDER_ROLE, config.vaultUnwinder);

        emit VaultCreated(address(this), address(token), config.roleAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param parameter Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParameter(
        bytes32 parameter,
        uint256 data
    ) external whenNotPaused onlyRole(VAULT_CONFIG_ROLE) {
        if (parameter == "debtFloor") vaultConfig.debtFloor = uint128(data);
        else if (parameter == "liquidationRatio")
            vaultConfig.liquidationRatio = uint64(data);
        else if (parameter == "baseRate") _setBaseRate(uint64(data));
        else if (parameter == "liquidationPenalty")
            liquidationConfig.liquidationPenalty = uint64(data);
        else if (parameter == "liquidationDiscount")
            liquidationConfig.liquidationDiscount = uint64(data);
        else revert CDPVault__setParameter_unrecognizedParameter();
        emit SetParameter(parameter, data);
    }

    function setParameter(
        bytes32 parameter,
        address data
    ) external whenNotPaused onlyRole(VAULT_CONFIG_ROLE) {
        if (parameter == "rewardController")
            rewardController = IChefIncentivesController(data);
        else revert CDPVault__setParameter_unrecognizedParameter();
        emit SetParameter(parameter, data);
    }

    /*//////////////////////////////////////////////////////////////
                      CASH BALANCE ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits collateral tokens into this contract and increases a users cash balance
    /// @dev The caller needs to approve this contract to transfer tokens on their behalf
    /// @param to Address of the user to attribute the cash to
    /// @param amount Amount of tokens to deposit [tokenScale]
    /// @return cashAmount Amount of cash deposited [wad]
    function deposit(
        address to,
        uint256 amount
    ) external whenNotPaused returns (uint256 cashAmount) {
        int256 deltaCollateral = toInt256(amount);
        modifyCollateralAndDebt({
            owner: to,
            collateralizer: msg.sender,
            creditor: msg.sender,
            deltaCollateral: deltaCollateral,
            deltaDebt: 0
        });

        //todo: perform the conversion
        cashAmount = amount;
    }

    /// @notice Withdraws collateral tokens from this contract and decreases a users cash balance
    /// @param to Address of the user to withdraw tokens to
    /// @param amount Amount of tokens to withdraw [wad]
    /// @return tokenAmount Amount of tokens withdrawn [tokenScale]
    function withdraw(
        address to,
        uint256 amount
    ) external whenNotPaused returns (uint256 tokenAmount) {
        int256 deltaCollateral = -toInt256(amount);
        modifyCollateralAndDebt({
            owner: msg.sender,
            collateralizer: to,
            creditor: msg.sender,
            deltaCollateral: deltaCollateral,
            deltaDebt: 0
        });
        //todo: perform conversion
        tokenAmount = amount;
    }

    function borrow(
        address borrower,
        address position,
        uint256 amount
    ) external {
        int256 deltaDebt = toInt256(amount);
        modifyCollateralAndDebt({
            owner: position,
            collateralizer: position,
            creditor: borrower,
            deltaCollateral: 0,
            deltaDebt: deltaDebt
        });
    }

    function repay(
        address borrower,
        address position,
        uint256 amount
    ) external {
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

    /*//////////////////////////////////////////////////////////////
                        POSITION ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates a position's collateral and normalized debt balances
    /// @dev This is the only method which is allowed to modify a position's collateral and normalized debt balances
    function _modifyPosition(
        address owner,
        Position memory position,
        uint256 newDebt,
        uint256 newCumulativeIndex,
        int256 deltaCollateral,
        uint256 totalDebt_
    ) internal returns (Position memory) {
        uint256 currentDebt = position.debt;
        // update collateral and normalized debt amounts by the deltas
        position.collateral = add(position.collateral, deltaCollateral);
        position.debt = newDebt; // U:[CM-10,11]
        position.cumulativeIndexLastUpdate = newCumulativeIndex; // U:[CM-10,11]
        position.lastDebtUpdate = uint64(block.number); // U:[CM-10,11]

        // position either has no debt or more debt than the debt floor
        if (
            position.debt != 0 && position.debt < uint256(vaultConfig.debtFloor)
        ) revert CDPVault__modifyPosition_debtFloor();

        // store the position's balances
        positions[owner] = position;

        // update the global debt balance
        if (newDebt > currentDebt) {
            totalDebt_ = totalDebt_ + (currentDebt - newDebt);
        } else {
            totalDebt_ = totalDebt_ - (newDebt - currentDebt);
        }
        totalNormalDebt = totalDebt_;

        if (address(rewardController) != address(0)) {
            rewardController.handleActionAfter(
                owner,
                position.debt,
                totalDebt_
            );
        }

        emit ModifyPosition(
            owner,
            position.debt,
            position.collateral,
            totalDebt_
        );

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
            ((deltaDebt > 0 || deltaCollateral < 0) &&
                !hasPermission(owner, msg.sender)) ||
            // msg.sender has the permission of the collateralizer to collateralize the position using their cash
            (deltaCollateral > 0 &&
                !hasPermission(collateralizer, msg.sender)) ||
            // msg.sender has the permission of the creditor to use their credit to repay the debt
            (deltaDebt < 0 && !hasPermission(creditor, msg.sender))
        ) revert CDPVault__modifyCollateralAndDebt_noPermission();

        Position memory position = positions[owner];
        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral(
            position
        );

        uint256 newDebt;
        uint256 newCumulativeIndex;
        uint256 profit;
        if (deltaDebt > 0) {
            (newDebt, newCumulativeIndex) = calcIncrease(
                uint256(deltaDebt), // delta debt
                position.debt,
                collateralDebtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                position.cumulativeIndexLastUpdate
            ); // U:[CM-10]

            IPoolV3(pool).lendCreditAccount(uint256(deltaDebt), creditor); // F:[CM-20]
        } else {
            uint256 maxRepayment = calcTotalDebt(collateralDebtData);
            uint256 amount = abs(deltaDebt);
            if (amount >= maxRepayment) {
                amount = maxRepayment; // U:[CM-11]
            }

            // ICreditAccountBase(creditor).transfer({token: underlying, to: pool, amount: amount}); // U:[CM-11]
            poolUnderlying.safeTransferFrom(creditor, pool, amount);

            if (amount == maxRepayment) {
                newDebt = 0;
                newCumulativeIndex = collateralDebtData.cumulativeIndexNow;
                profit = collateralDebtData.accruedFees;
            } else {
                (newDebt, newCumulativeIndex, profit) = calcDecrease(
                    amount, // delta debt
                    position.debt,
                    collateralDebtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                    position.cumulativeIndexLastUpdate
                );
            }

            IPoolV3(pool).repayCreditAccount(
                collateralDebtData.debt - newDebt,
                profit,
                0
            ); // U:[CM-11]
        }

        // todo: transfer collateral
        if (deltaCollateral > 0) {
            uint256 amount = deltaCollateral.toUint256();
            token.safeTransferFrom(collateralizer, address(this), amount);
        } else if (deltaCollateral < 0) {
            uint256 amount = abs(deltaCollateral);
            token.safeTransfer(collateralizer, amount);
        }

        // todo: check total debt ceiling

        position = _modifyPosition(
            owner,
            position,
            newDebt,
            newCumulativeIndex,
            deltaCollateral,
            totalNormalDebt
        );

        VaultConfig memory config = vaultConfig;
        uint256 spotPrice_ = spotPrice();
        uint256 collateralValue = wmul(position.collateral, spotPrice_);

        if (
            (deltaDebt > 0 || deltaCollateral < 0) &&
            !_isCollateralized(
                newDebt,
                collateralValue,
                config.liquidationRatio
            )
        ) revert CDPVault__modifyCollateralAndDebt_notSafe();

        emit ModifyCollateralAndDebt(
            owner,
            collateralizer,
            creditor,
            deltaCollateral,
            deltaDebt
        );
    }

    function _calcDebtAndCollateral(
        Position memory position
    ) internal view returns (CollateralDebtData memory cdd) {
        uint256 index = IPoolV3Loop(pool).baseInterestIndex();
        cdd.debt = position.debt;
        cdd.cumulativeIndexNow = index;
        cdd.cumulativeIndexLastUpdate = position.cumulativeIndexLastUpdate;

        cdd.accruedInterest = calcAccruedInterest(
            cdd.debt,
            cdd.cumulativeIndexLastUpdate,
            index
        );

        cdd.accruedFees =
            (cdd.accruedInterest * feeInterest) /
            PERCENTAGE_FACTOR;
    }

    function _updatePosition(
        address position
    ) internal view returns (Position memory updatedPos) {
        Position memory pos = positions[position];
        // pos.cumulativeIndexLastUpdate =
        uint256 accruedInterest = calcAccruedInterest(
            pos.debt,
            pos.cumulativeIndexLastUpdate,
            IPoolV3Loop(pool).baseInterestIndex()
        );
        uint256 currentDebt = pos.debt + accruedInterest;
        uint256 spotPrice_ = spotPrice();
        uint256 collateralValue = wmul(pos.collateral, spotPrice_);

        if (
            spotPrice_ == 0 ||
            _isCollateralized(
                currentDebt,
                collateralValue,
                vaultConfig.liquidationRatio
            )
        ) revert CDPVault__modifyCollateralAndDebt_notSafe();

        return pos;
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidates a single unsafe positions by selling collateral at a discounted (`liquidationDiscount`)
    /// oracle price. The liquidator has to provide the amount he wants to repay or sell (`repayAmounts`) for
    /// the position. From that repay amount a penalty (`liquidationPenalty`) is subtracted to mitigate against
    /// profitable self liquidations. If the available collateral of a position is not sufficient to cover the debt
    /// the vault accumulates 'bad debt'.
    /// @dev The liquidator has to approve the vault to transfer the sum of `repayAmounts`.
    /// @param owner Owner of the position to liquidate
    /// @param repayAmount Amount the liquidator wants to repay [wad]
    function liquidatePosition(
        address owner,
        uint256 repayAmount
    ) external whenNotPaused {
        // validate params
        if (owner == address(0) || repayAmount == 0)
            revert CDPVault__liquidatePosition_invalidParameters();

        // load configs
        VaultConfig memory config = vaultConfig;
        LiquidationConfig memory liqConfig_ = liquidationConfig;

        // load liquidated position
        Position memory position = positions[owner];

        // load price and calculate discounted price
        uint256 spotPrice_ = spotPrice();
        uint256 discountedPrice = wmul(
            spotPrice_,
            liqConfig_.liquidationDiscount
        );

        // update debt
        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral(
            position
        );

        // compute collateral to take, debt to repay and penalty to pay
        uint256 takeCollateral = wdiv(repayAmount, discountedPrice);
        uint256 deltaDebt = wmul(repayAmount, liqConfig_.liquidationPenalty);
        uint256 penalty = wmul(
            repayAmount,
            WAD - liqConfig_.liquidationPenalty
        );

        // uint256 accruedInterest = calcAccruedInterest(
        //     position.debt,
        //     position.cumulativeIndexLastUpdate,
        //     IPoolV3Loop(pool).baseInterestIndex()
        // );
        // uint256 currentDebt = position.debt + accruedInterest;
        uint256 collateralValue = wmul(position.collateral, spotPrice_);

        // verify that the position is indeed unsafe
        if (
            spotPrice_ == 0 ||
            _isCollateralized(
                collateralDebtData.debt,
                collateralValue,
                config.liquidationRatio
            )
        ) revert CDPVault__liquidatePosition_notUnsafe();

        // account for bad debt
        // TODO: review this
        if (takeCollateral > position.collateral) {
            takeCollateral = position.collateral;
            repayAmount = wmul(takeCollateral, discountedPrice);
            penalty = wmul(repayAmount, WAD - liqConfig_.liquidationPenalty);
            // debt >= repayAmount if takeCollateral > position.collateral
            //deltaDebt = currentDebt;
            deltaDebt = collateralDebtData.debt;
        }

        // update liquidated position
        // _modifyPosition(
        //     owner,
        //     position,
        //     currentDebt,
        //     -toInt256(takeCollateral),
        //     -toInt256(deltaDebt),
        //     totalNormalDebt
        // );

        // update vault state
        // totalNormalDebt -= deltaDebt;

        // transfer the repay amount from the liquidator to the vault
        // cdm.modifyBalance(msg.sender, address(this), repayAmount);
        poolUnderlying.safeTransferFrom(msg.sender, pool, deltaDebt);

        uint256 newDebt;
        uint256 newCumulativeIndex;
        uint256 profit;
        uint256 maxRepayment = calcTotalDebt(collateralDebtData);
        if (deltaDebt == maxRepayment) {
            newDebt = 0;
            newCumulativeIndex = collateralDebtData.cumulativeIndexNow;
            profit = collateralDebtData.accruedFees;
        } else {
            (newDebt, newCumulativeIndex, profit) = calcDecrease(
                deltaDebt, // delta debt
                collateralDebtData.debt,
                collateralDebtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                collateralDebtData.cumulativeIndexLastUpdate
            );
        }

        IPoolV3(pool).repayCreditAccount(
            collateralDebtData.debt - newDebt,
            profit,
            0
        ); // U:[CM-11]
        // transfer the cash amount from the vault to the liquidator
        // cash[msg.sender] += takeCollateral;
        token.safeTransfer(msg.sender, takeCollateral);

        // Mint the penalty from the vault to the treasury
        // cdm.modifyBalance(address(this), address(buffer), penalty);
        IPoolV3Loop(pool).mintProfit(penalty);

        position.debt = newDebt;
        position.lastDebtUpdate = block.timestamp;
        position.cumulativeIndexLastUpdate = newCumulativeIndex;
    }

    /// @dev Computes new debt principal and interest index after increasing debt
    ///      - The new debt principal is simply `debt + amount`
    ///      - The new credit account's interest index is a solution to the equation
    ///        `debt * (indexNow / indexLastUpdate - 1) = (debt + amount) * (indexNow / indexNew - 1)`,
    ///        which essentially writes that interest accrued since last update remains the same
    /// @param amount Amount to increase debt by
    /// @param debt Debt principal before increase
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @return newDebt Debt principal after increase
    /// @return newCumulativeIndex New credit account's interest index
    function calcIncrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate
    ) internal pure returns (uint256 newDebt, uint256 newCumulativeIndex) {
        if (debt == 0) return (amount, cumulativeIndexNow);
        newDebt = debt + amount; // U:[CL-2]
        newCumulativeIndex = ((cumulativeIndexNow * newDebt * INDEX_PRECISION) /
            ((INDEX_PRECISION * cumulativeIndexNow * debt) /
                cumulativeIndexLastUpdate +
                INDEX_PRECISION *
                amount)); // U:[CL-2]
    }

    /// @dev Computes interest accrued since the last update
    function calcAccruedInterest(
        uint256 amount,
        uint256 cumulativeIndexLastUpdate,
        uint256 cumulativeIndexNow
    ) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return
            (amount * cumulativeIndexNow) / cumulativeIndexLastUpdate - amount; // U:[CL-1]
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
    // @param cumulativeQuotaInterest Credit account's quota interest before repayment
    // @param quotaFees Accrued quota fees
    // @param feeInterest Fee on accrued interest (both base and quota) charged by the DAO
    /// @return newDebt Debt principal after repayment
    /// @return newCumulativeIndex Credit account's quota interest after repayment
    /// @return profit Amount of underlying tokens received as fees by the DAO
    // @return newCumulativeQuotaInterest Credit account's accrued quota interest after repayment
    // @return newQuotaFees Amount of unpaid quota fees left after repayment
    function calcDecrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate
    )
        internal
        view
        returns (uint256 newDebt, uint256 newCumulativeIndex, uint256 profit)
    {
        uint256 amountToRepay = amount;

        if (amountToRepay != 0) {
            uint256 interestAccrued = calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
                cumulativeIndexNow: cumulativeIndexNow
            }); // U:[CL-3]
            uint256 profitFromInterest = (interestAccrued * feeInterest) /
                PERCENTAGE_FACTOR; // U:[CL-3]

            if (amountToRepay >= interestAccrued + profitFromInterest) {
                amountToRepay -= interestAccrued + profitFromInterest;

                profit += profitFromInterest; // U:[CL-3]

                newCumulativeIndex = cumulativeIndexNow; // U:[CL-3]
            } else {
                // If amount is not enough to repay base interest + DAO fee, then it is split pro-rata between them
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) /
                    (PERCENTAGE_FACTOR + feeInterest);

                profit += amountToRepay - amountToPool; // U:[CL-3]
                amountToRepay = 0; // U:[CL-3]

                newCumulativeIndex =
                    (INDEX_PRECISION *
                        cumulativeIndexNow *
                        cumulativeIndexLastUpdate) /
                    (INDEX_PRECISION *
                        cumulativeIndexNow -
                        (INDEX_PRECISION *
                            amountToPool *
                            cumulativeIndexLastUpdate) /
                        debt); // U:[CL-3]
            }
        } else {
            newCumulativeIndex = cumulativeIndexLastUpdate; // U:[CL-3]
        }
        newDebt = debt - amountToRepay; // U:[CL-3]
    }

    /// @dev Computes total debt, given raw debt data
    /// @param collateralDebtData See `CollateralDebtData` (must have debt data filled)
    function calcTotalDebt(
        CollateralDebtData memory collateralDebtData
    ) internal pure returns (uint256) {
        return
            collateralDebtData.debt +
            collateralDebtData.accruedInterest +
            collateralDebtData.accruedFees;
    }
}
