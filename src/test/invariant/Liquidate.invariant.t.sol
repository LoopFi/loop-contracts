// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {LiquidateHandler} from "./handlers/LiquidateHandler.sol";
import {BorrowHandler} from "./handlers/BorrowHandler.sol";
import {wmul} from "../../utils/Math.sol";
import {CDPVault} from "../../CDPVault.sol";
import {CDPVaultWrapper} from "./CDPVaultWrapper.sol";

/// @title LiquidateInvariantTest
contract LiquidateInvariantTest is InvariantTestBase {
    CDPVaultWrapper internal vault;
    LiquidateHandler internal liquidateHandler;

    uint64 public liquidationRatio = 1.25 ether;
    uint64 public targetHealthFactor = 1.10 ether;

    /// ======== Setup ======== ///

    function setUp() public virtual override {
        super.setUp();

        uint64 liquidationPenalty = uint64(0.99 ether);

        vault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: liquidationRatio,
            liquidationPenalty:liquidationPenalty,
            liquidationDiscount: 0.98 ether, 
            baseRate: BASE_RATE_1_005
        });

        CDPVault.IRS memory irs = vault.getIRS();
        assertEq(irs.baseRate, BASE_RATE_1_005);
        GhostVariableStorage ghostVariableStorage = new GhostVariableStorage();
        liquidateHandler = new LiquidateHandler(vault, this, ghostVariableStorage, liquidationRatio, targetHealthFactor, liquidationPenalty);
        _setupVaults();

        excludeSender(address(vault));
        excludeSender(address(liquidateHandler));

        vm.label({account: address(vault), newLabel: "CDPVault"});
        vm.label({
            account: address(liquidateHandler),
            newLabel: "LiquidateHandler"
        });

        (bytes4[] memory selectors, ) = liquidateHandler.getTargetSelectors();
        targetSelector(
            FuzzSelector({
                addr: address(liquidateHandler),
                selectors: selectors
            })
        );

        targetContract(address(liquidateHandler));
    }

    // deploy a reserve vault and create credit for the borrow handler
    function _setupVaults() private {
        deal(
            address(token),
            address(liquidateHandler),
            liquidateHandler.collateralReserve() + liquidateHandler.creditReserve()
        );

        // prepare collateral
        vm.startPrank(address(liquidateHandler));
        token.approve(address(vault), liquidateHandler.collateralReserve());
        vault.deposit(address(liquidateHandler), liquidateHandler.collateralReserve());
        cdm.modifyPermission(address(vault),true);        
        vm.stopPrank();

        CDPVault creditVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: liquidateHandler.creditReserve(), 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            baseRate: 1 ether
        });

        // increase the global debt ceiling
        setGlobalDebtCeiling(
            initialGlobalDebtCeiling + liquidateHandler.creditReserve()
        );

        vm.startPrank(address(liquidateHandler));
        token.approve(address(creditVault), liquidateHandler.creditReserve());
        creditVault.deposit(
            address(liquidateHandler),
            liquidateHandler.creditReserve()
        );

        creditVault.modifyCollateralAndDebt(
            address(liquidateHandler),
            address(liquidateHandler),
            address(liquidateHandler),
            int256(liquidateHandler.creditReserve()),
            int256(wmul(liquidationPrice(creditVault), liquidateHandler.creditReserve()))
        );
        vm.stopPrank();
    }

    function invariant_Liquidation_A() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_A(liquidateHandler); }

    function invariant_Liquidation_B() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_B(vault, liquidateHandler); }

    function invariant_Liquidation_C() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_C(vault, liquidateHandler); }

    function invariant_Liquidation_D() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_D(liquidateHandler); }
    
    function invariant_Liquidation_E() external useCurrentTimestamp printReport(liquidateHandler) { assert_invariant_Liquidation_E(vault, liquidateHandler); }
 }
