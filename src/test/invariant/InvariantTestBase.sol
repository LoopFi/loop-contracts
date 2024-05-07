// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../invariant/handlers/BaseHandler.sol";
import {LiquidateHandler} from "../invariant/handlers/LiquidateHandler.sol";

import {TestBase} from "../TestBase.sol";

import {CDPVaultConstants, CDPVaultConfig} from "../../interfaces/ICDPVault.sol";

import {WAD, wmul, wdiv} from "../../utils/Math.sol";

import {CDM, ACCOUNT_CONFIG_ROLE, getCredit, getDebt} from "../../CDM.sol";
import {CDPVault, calculateDebt} from "../../CDPVault.sol";
import {InterestRateModel} from "../../InterestRateModel.sol";
import {CDPVaultWrapper} from "./CDPVaultWrapper.sol";

/// @title InvariantTestBase
/// @notice Base test contract with common logic needed by all invariant test contracts.
contract InvariantTestBase is TestBase {
    uint256 internal constant EPSILON = 500;

    uint64 internal constant BASE_RATE_1_0 = 1 ether; // 0% base rate
    uint64 internal constant BASE_RATE_1_005 = 1000000000157721789; // 0.5% base rate
    uint64 internal constant BASE_RATE_1_025 = 1000000000780858271; // 2.5% base rate

    /// ======== Storage ======== ///

    modifier printReport(BaseHandler handler) {
        _;
        handler.printCallReport();
    }

    function setUp() public virtual override {
        super.setUp();
        filterSenders();
    }

    /// ======== Stablecoin Invariant Asserts ======== ///
    /*
    Stablecoin Invariants:
        - Invariant A: sum of balances for all holders is equal to `totalSupply` of `Stablecoin`
        - Invariant B: conservation of `Stablecoin` is maintained
    */

    // Invariant A: sum of balances for all holders is equal to `totalSupply` of `Stablecoin`
    function assert_invariant_Stablecoin_A(uint256 totalUserBalance) public {
        assertEq(stablecoin.totalSupply(), totalUserBalance);
    }

    // Invariant B: conservation of `Stablecoin` is maintained
    function assert_invariant_Stablecoin_B(
        uint256 mintAccumulator,
        uint256 burnAccumulator
    ) public {
        uint256 stablecoinInExistence = mintAccumulator - burnAccumulator;
        assertEq(stablecoin.totalSupply(), stablecoinInExistence);
    }

    /// ======== PSM Invariant Asserts ======== ///
    /*
    PSM Invariants:
        - Invariant A: `totalSupply` of `Stablecoin` is equal to `globalDebt` and is equal to the collateral balance of the PSM
    */

    // Invariant A: `totalSupply` of `Stablecoin` is equal to `globalDebt` and is equal to the collateral balance of the PSM
    function assert_invariant_PSM_A(uint256 psmCollateralBalance) public {
        uint256 totalSupply = stablecoin.totalSupply();
        uint256 globalDebt = cdm.globalDebt();

        assertEq(totalSupply, globalDebt);
        assertEq(globalDebt, psmCollateralBalance);
    }

    /// ======== CDM Invariant Asserts ======== ///
    /*
    CDM Invariants:
        - Invariant A: `totalSupply` of `Stablecoin` is less or equal to `globalDebt`
        - Invariant B: `globalDebt` is less or equal to `globalDebtCeiling`
        - Invariant C: sum of `credit` for all accounts is less or equal to `globalDebt`
        - Invariant D: sum of `debt` for all `Vaults` is less or equal to `globalDebt`
        - Invariant E: sum of `debt` for a `Vault` is less or equal to `debtCeiling`
    */

    // Invariant A: `totalSupply` of `Stablecoin` is less or equal to `globalDebt`
    function assert_invariant_CDM_A() public {
        assertLe(stablecoin.totalSupply(), cdm.globalDebt());
    }

    // Invariant B: `globalDebt` is less or equal to `globalDebtCeiling`
    function assert_invariant_CDM_B() public {
        assertGe(cdm.globalDebtCeiling(), cdm.globalDebt());
    }

    // Invariant C: sum of `credit` for all accounts is less or equal to `globalDebt`
    function assert_invariant_CDM_C(BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        uint256 totalUserCredit = 0;
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (int256 balance, ) = cdm.accounts(user);
            totalUserCredit += getCredit(balance);
        }

        assertGe(cdm.globalDebt(), totalUserCredit);
    }

    // Invariant D: sum of `debt` for all `Vaults` is less or equal to `globalDebt`
    function assert_invariant_CDM_D(BaseHandler handler) public {
        uint256 vaultCount = handler.count(VAULTS_CATEGORY);
        uint256 totalVaultDebt = 0;
        for (uint256 i = 0; i < vaultCount; ++i) {
            address vault = handler.getActor(VAULTS_CATEGORY, i);
            (int256 balance, ) = cdm.accounts(vault);
            totalVaultDebt += getDebt(balance);
        }

        assertGe(cdm.globalDebt(), totalVaultDebt);
    }

    // Invariant E: sum of `debt` for a `Vault` is less or equal to `debtCeiling`
    function assert_invariant_CDM_E(BaseHandler handler) public {
        uint256 vaultCount = handler.count(VAULTS_CATEGORY);
        uint256 totalVaultDebt = 0;
        for (uint256 i = 0; i < vaultCount; ++i) {
            address vault = handler.getActor(VAULTS_CATEGORY, i);
            (int256 balance, ) = cdm.accounts(vault);
            totalVaultDebt += getDebt(balance);
        }

        assertGe(cdm.globalDebtCeiling(), totalVaultDebt);
    }

    /// ======== CDPVault Invariant Asserts ======== ///

    /*
    CDPVault Invariants:
        - Invariant A: `balanceOf` collateral `token`'s of a `CDPVault` is greater or equal to the sum of all the `CDPVault`'s `Position`'s `collateral` amounts and the sum of all `cash` balances
        - Invariant B: sum of `normalDebt` of all `Positions` is equal to `totalNormalDebt`
        - Invariant C: sum of `normalDebt * rateAccumulator` (debt) across all positions = `totalNormalDebt * rateAccumulator` (totalDebt)
        - Invariant D: `debt` for all `Positions` is greater than `debtFloor` or zero
        - Invariant E: all `Positions` are safe
    */

    // Invariant A: `balanceOf` collateral `token`'s of a `CDPVault` is greater or equal to the sum of all the `CDPVault`'s `Position`'s `collateral` amounts and the sum of all `cash` balances
    function assert_invariant_CDPVault_A(
        CDPVault vault,
        BaseHandler handler
    ) public {
        uint256 totalCollateralBalance = 0;
        uint256 totalCashBalance = 0;

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (uint256 collateral, , , , ) = vault.positions(user);
            totalCollateralBalance += collateral;
            totalCashBalance += vault.cash(user);
        }

        uint256 vaultBalance = token.balanceOf(address(vault));

        assertGe(vaultBalance, totalCollateralBalance + totalCashBalance);
    }

    // Invariant B: sum of `normalDebt` of all `Positions` is equal to `totalNormalDebt`
    function assert_invariant_CDPVault_B(
        CDPVault vault,
        BaseHandler handler
    ) public {
        uint256 totalNormalDebt = 0;

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 normalDebt, , , ) = vault.positions(user);
            totalNormalDebt += normalDebt;
        }

        assertEq(totalNormalDebt, vault.totalNormalDebt());
    }

    // Invariant C: `debt` for all `Positions` is greater than `debtFloor` or zero
    function assert_invariant_CDPVault_C(
        CDPVault vault,
        BaseHandler handler
    ) public {
        (uint128 debtFloor, ) = vault.vaultConfig();

        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (, uint256 normalDebt, , , ) = vault.positions(user);
            if (normalDebt != 0) {
                assertGe(normalDebt, debtFloor);
            }
        }
    }

    // - Invariant D: all `Positions` are safe
    function assert_invariant_CDPVault_D(
        CDPVault vault,
        BaseHandler handler
    ) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (uint256 collateral, uint256 normalDebt, , , ) = vault.positions(
                user
            );
            // ensure that the position is safe (i.e. collateral * liquidationPrice >= normalDebt)
            assertGe(wmul(collateral, liquidationPrice(vault)), normalDebt);
        }
    }

    /// ======== Interest Rate Model Invariant Asserts ======== ///

    /*
    Interest Rate Model Invariants:
        - Invariant A: 1 <= `rateAccumulator`
        - Invariant B: `rateAccumulator` at block x <= `rateAccumulator` at block y, if x < y and specifically if `rateAccumulator` was updated in between the blocks x and y
        - Invariant C: `virtualRateAccumulator` is equal to `rateAccumulator` post update
    */

    // - Invariant A: 1 <= `rateAccumulator`
    function assert_invariant_IRM_A(CDPVault vault) public {
        CDPVault.IRS memory irs = vault.getIRS();
        assertGe(irs.rateAccumulator, WAD);
    }

    // - Invariant B: `rateAccumulator` at block x <= `rateAccumulator` at block y, if x < y and specifically if `rateAccumulator` was updated in between the blocks x and y
    function assert_invariant_IRM_B(BaseHandler handler) public {
        uint256 userCount = handler.count(USERS_CATEGORY);

        for (uint256 i = 0; i < userCount; ++i) {
            address user = handler.getActor(USERS_CATEGORY, i);
            (bytes32 prevValue, bytes32 value) = handler.getTrackedValue(
                getValueKey(user, RATE_ACCUMULATOR)
            );
            assertGe(uint256(value), uint256(prevValue));
        }
    }

    // - Invariant C: `virtualRateAccumulator` is equal to `rateAccumulator` post update
    function assert_invariant_IRM_C(
        CDPVaultWrapper vault,
        BaseHandler handler
    ) public {
        uint256 userCount = handler.count(USERS_CATEGORY);
        if (userCount == 0) return;
        uint64 rateAccumulator = vault.virtualRateAccumulator();
        address user = handler.getActor(USERS_CATEGORY, 0);
        vault.modifyCollateralAndDebt(user, user, user, 0, 0);
        CDPVault.IRS memory irs = vault.getIRS();
        assertApproxEqAbs(
            uint256(rateAccumulator),
            uint256(irs.rateAccumulator),
            100
        );
    }

    /// ======== Liquidation Invariant Asserts ======== ///
    /*
    Liquidation Invariants:
        - Invariant A: liquidator should never pay more than `repayAmount`
        - Invariant B: credit paid should never be larger than `debt` / `liquidationPenalty`
        - Invariant C: `position.collateral` should be zero if `position.normalDebt` is zero for a liquidated position
        - Invariant D: `accruedBadDebt` should never exceed the sum of `debt` of liquidated positions
        - Invariant E: delta debt should be equal to credit paid * `liquidationPenalty` + badDebt
    */

    // - Invariant A: liquidator should never pay more than `repayAmount`
    function assert_invariant_Liquidation_A(LiquidateHandler handler) public {
        address position = handler.liquidatedPosition();
        uint256 repayAmount = handler.getRepayAmount(position);

        uint256 creditPaid = handler.creditPaid();
        assertLe(creditPaid, repayAmount);
    }

    // - Invariant B: credit paid should never be larger than `debt` / `liquidationPenalty`
    function assert_invariant_Liquidation_B(
        CDPVaultWrapper vault,
        LiquidateHandler handler
    ) public {
        (uint64 liquidationPenalty, ) = vault.liquidationConfig();
        uint256 totalDebt = handler.preLiquidationDebt();
        uint256 creditPaid = handler.creditPaid();
        assertLe(creditPaid, wdiv(totalDebt, liquidationPenalty));
    }

    // - Invariant C: `position.collateral` should be zero if `position.normalDebt` is zero for a liquidated position
    function assert_invariant_Liquidation_C(
        CDPVaultWrapper vault,
        LiquidateHandler handler
    ) public {
        address user = handler.liquidatedPosition();
        (uint256 collateral, uint256 normalDebt, , , ) = vault.positions(user);
        if (collateral == 0) {
            assertEq(normalDebt, 0);
        }
    }

    // - Invariant D: `accruedBadDebt` should never exceed the sum of `debt` of liquidated positions
    function assert_invariant_Liquidation_D(LiquidateHandler handler) public {
        uint256 totalDebt = handler.preLiquidationDebt();
        uint256 accruedBadDebt = handler.accruedBadDebt();
        assertGe(totalDebt, accruedBadDebt);
    }

    // - Invariant E: delta debt should be equal to credit paid * `liquidationPenalty` + badDebt
    function assert_invariant_Liquidation_E(
        CDPVaultWrapper vault,
        LiquidateHandler handler
    ) public {
        (uint64 liquidationPenalty, ) = vault.liquidationConfig();
        uint256 creditPaid = handler.creditPaid();
        uint256 deltaDebt = handler.preLiquidationDebt() -
            handler.postLiquidationDebt();
        uint256 accruedBadDebt = handler.accruedBadDebt();

        assertApproxEqAbs(
            deltaDebt,
            wmul(creditPaid, liquidationPenalty) + accruedBadDebt,
            EPSILON
        );
    }

    /// ======== Helper Functions ======== ///

    function filterSenders() internal virtual {
        excludeSender(address(cdm));
        excludeSender(address(stablecoin));
        excludeSender(address(flashlender));
        excludeSender(address(minter));
        excludeSender(address(buffer));
        excludeSender(address(token));
        excludeSender(address(oracle));
    }

    function createCDPVaultWrapper(
        IERC20 token_,
        uint256 debtCeiling,
        uint128 debtFloor,
        uint64 liquidationRatio,
        uint64 liquidationPenalty,
        uint64 liquidationDiscount,
        uint256 baseRate
    ) internal returns (CDPVaultWrapper vault) {
        CDPVaultConstants memory constants = CDPVaultConstants({
            cdm: cdm,
            oracle: oracle,
            buffer: buffer,
            token: token_,
            tokenScale: 10 ** IERC20Metadata(address(token_)).decimals()
        });

        CDPVaultConfig memory configs = CDPVaultConfig({
            debtFloor: debtFloor,
            liquidationRatio: liquidationRatio,
            liquidationPenalty: liquidationPenalty,
            liquidationDiscount: liquidationDiscount,
            baseRate: baseRate,
            roleAdmin: address(this),
            vaultAdmin: address(this),
            pauseAdmin: address(this),
            vaultUnwinder: address(this)
        });
        vault = new CDPVaultWrapper(constants, configs);

        if (debtCeiling > 0) {
            constants.cdm.setParameter(
                address(vault),
                "debtCeiling",
                debtCeiling
            );
        }

        cdm.modifyPermission(address(vault), true);

        (int256 balance, uint256 debtCeiling_) = cdm.accounts(address(vault));
        assertEq(balance, 0);
        assertEq(debtCeiling_, debtCeiling);

        vm.label({account: address(vault), newLabel: "CDPVaultWrapper"});
    }
}
