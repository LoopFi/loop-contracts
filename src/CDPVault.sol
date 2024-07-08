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
function calculateDebt(uint256 normalDebt, uint64 rateAccumulator) pure returns (uint256 debt) {
    debt = wmul(normalDebt, rateAccumulator);
}

/// @notice Calculates the normalized debt from an actual debt amount
/// @param debt Actual debt (either of a position or the total debt)
/// @param rateAccumulator Rate accumulator
/// @return normalDebt Normalized debt [wad]
function calculateNormalDebt(uint256 debt, uint64 rateAccumulator) pure returns (uint256 normalDebt) {
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

    /// @dev Percentage of accrued interest in bps taken by the protocol as profit
    uint16 internal feeInterest;

    uint16 constant PERCENTAGE_FACTOR = 1e4; // percentage with two decimal precision

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
    function deposit(address to, uint256 amount) external whenNotPaused returns (uint256 tokenAmount) {
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
    function withdraw(address to, uint256 amount) external whenNotPaused returns (uint256 tokenAmount) {
        tokenAmount = wmul(amount, tokenScale);
        int256 deltaCollateral = -toInt256(tokenAmount);
        modifyCollateralAndDebt({
            owner: msg.sender,
            collateralizer: to,
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

        Position memory position = positions[owner];
        DebtData memory debtData = _calcDebt(position);

        uint256 newDebt;
        uint256 newCumulativeIndex;
        uint256 profit;
        if (deltaDebt > 0) {
            (newDebt, newCumulativeIndex) = calcIncrease(
                uint256(deltaDebt), // delta debt
                position.debt,
                debtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                position.cumulativeIndexLastUpdate
            ); // U:[CM-10]

            pool.lendCreditAccount(uint256(deltaDebt), creditor); // F:[CM-20]
        } else if (deltaDebt < 0) {
            uint256 maxRepayment = calcTotalDebt(debtData);
            uint256 amount = abs(deltaDebt);
            if (amount >= maxRepayment) {
                amount = maxRepayment; // U:[CM-11]
            }

            poolUnderlying.safeTransferFrom(creditor, address(pool), amount);

            if (amount == maxRepayment) {
                newDebt = 0;
                newCumulativeIndex = debtData.cumulativeIndexNow;
                profit = debtData.accruedFees;
            } else {
                (newDebt, newCumulativeIndex, profit) = calcDecrease(
                    amount, // delta debt
                    position.debt,
                    debtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                    position.cumulativeIndexLastUpdate
                );
            }

            pool.repayCreditAccount(debtData.debt - newDebt, profit, 0); // U:[CM-11]
        }

        if (deltaCollateral > 0) {
            uint256 amount = deltaCollateral.toUint256();
            token.safeTransferFrom(collateralizer, address(this), amount);
        } else if (deltaCollateral < 0) {
            uint256 amount = abs(deltaCollateral);
            token.safeTransfer(collateralizer, amount);
        }

        position = _modifyPosition(owner, position, newDebt, newCumulativeIndex, deltaCollateral, totalDebt);

        VaultConfig memory config = vaultConfig;
        uint256 spotPrice_ = spotPrice();
        uint256 collateralValue = wmul(position.collateral, spotPrice_);

        if (
            (deltaDebt > 0 || deltaCollateral < 0) &&
            !_isCollateralized(newDebt, collateralValue, config.liquidationRatio)
        ) revert CDPVault__modifyCollateralAndDebt_notSafe();

        emit ModifyCollateralAndDebt(owner, collateralizer, creditor, deltaCollateral, deltaDebt);
    }

    /// @notice Returns the total debt and the accrued interest of a position
    function _calcDebt(Position memory position) internal view returns (DebtData memory cdd) {
        uint256 index = pool.baseInterestIndex();
        cdd.debt = position.debt;
        cdd.cumulativeIndexNow = index;
        cdd.cumulativeIndexLastUpdate = position.cumulativeIndexLastUpdate;

        cdd.accruedInterest = calcAccruedInterest(cdd.debt, cdd.cumulativeIndexLastUpdate, index);

        cdd.accruedFees = (cdd.accruedInterest * feeInterest) / PERCENTAGE_FACTOR;
    }

    function _updatePosition(address position) internal view returns (Position memory updatedPos) {
        Position memory pos = positions[position];
        uint256 accruedInterest = calcAccruedInterest(
            pos.debt,
            pos.cumulativeIndexLastUpdate,
            pool.baseInterestIndex()
        );
        uint256 currentDebt = pos.debt + accruedInterest;
        uint256 spotPrice_ = spotPrice();
        uint256 collateralValue = wmul(pos.collateral, spotPrice_);

        if (spotPrice_ == 0 || _isCollateralized(currentDebt, collateralValue, vaultConfig.liquidationRatio))
            revert CDPVault__modifyCollateralAndDebt_notSafe();

        return pos;
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

        // compute collateral to take, debt to repay and penalty to pay
        uint256 takeCollateral = wdiv(repayAmount, discountedPrice);
        uint256 deltaDebt = wmul(repayAmount, liqConfig_.liquidationPenalty);
        uint256 penalty = wmul(repayAmount, WAD - liqConfig_.liquidationPenalty);

        // verify that the position is indeed unsafe
        if (_isCollateralized(debtData.debt, wmul(position.collateral, spotPrice_), config.liquidationRatio))
            revert CDPVault__liquidatePosition_notUnsafe();

        // account for bad debt
        if (takeCollateral > position.collateral) {
            takeCollateral = position.collateral;
            repayAmount = wmul(takeCollateral, discountedPrice);
            penalty = wmul(repayAmount, WAD - liqConfig_.liquidationPenalty);
            deltaDebt = debtData.debt;
        }

        // update vault state
        totalDebt -= deltaDebt;

        // transfer the repay amount from the liquidator to the vault
        poolUnderlying.safeTransferFrom(msg.sender, address(pool), deltaDebt);

        uint256 newDebt;
        uint256 profit;
        uint256 maxRepayment = calcTotalDebt(debtData);
        {
            uint256 newCumulativeIndex;
            if (deltaDebt == maxRepayment) {
                newDebt = 0;
                newCumulativeIndex = debtData.cumulativeIndexNow;
                profit = debtData.accruedFees;
            } else {
                (newDebt, newCumulativeIndex, profit) = calcDecrease(
                    deltaDebt, // delta debt
                    debtData.debt,
                    debtData.cumulativeIndexNow, // current cumulative base interest index in Ray
                    debtData.cumulativeIndexLastUpdate
                );
            }
            // update liquidated position
            position = _modifyPosition(owner, position, newDebt, newCumulativeIndex, -toInt256(takeCollateral), totalDebt);
        }

        pool.repayCreditAccount(debtData.debt - newDebt, profit, 0);
        token.safeTransfer(msg.sender, takeCollateral);

        // Mint the penalty from the vault to the treasury
        IPoolV3Loop(address(pool)).mintProfit(penalty);
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
        newDebt = debt + amount;
        newCumulativeIndex = ((cumulativeIndexNow * newDebt * INDEX_PRECISION) /
            ((INDEX_PRECISION * cumulativeIndexNow * debt) / cumulativeIndexLastUpdate + INDEX_PRECISION * amount));
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
    function calcDecrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate
    ) internal view returns (uint256 newDebt, uint256 newCumulativeIndex, uint256 profit) {
        uint256 amountToRepay = amount;

        if (amountToRepay != 0) {
            uint256 interestAccrued = calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
                cumulativeIndexNow: cumulativeIndexNow
            });
            uint256 profitFromInterest = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

            if (amountToRepay >= interestAccrued + profitFromInterest) {
                amountToRepay -= interestAccrued + profitFromInterest;
                profit += profitFromInterest;
                newCumulativeIndex = cumulativeIndexNow;
            } else {
                uint256 amountToPool = (amountToRepay * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);
                profit += amountToRepay - amountToPool;
                amountToRepay = 0;
                newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate) /
                    (INDEX_PRECISION * cumulativeIndexNow - (INDEX_PRECISION * amountToPool * cumulativeIndexLastUpdate) /
                        debt);
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
        return debtData.debt + debtData.accruedInterest + debtData.accruedFees;
    }
}
