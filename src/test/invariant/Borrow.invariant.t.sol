// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {BorrowHandler} from "./handlers/BorrowHandler.sol";

import {wmul} from "../../utils/Math.sol";
import {CDPVault, VAULT_CONFIG_ROLE} from "../../CDPVault.sol";
import {CDPVaultWrapper} from "./CDPVaultWrapper.sol";

/// @title BorrowInvariantTest
contract BorrowInvariantTest is InvariantTestBase {
    CDPVaultWrapper internal cdpVault;
    BorrowHandler internal borrowHandler;

    /// ======== Setup ======== ///

    function setUp() public virtual override {
        super.setUp();

        cdpVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            baseRate: 1 ether
        });

        borrowHandler = new BorrowHandler(cdpVault, this, new GhostVariableStorage());

        cdpVault.grantRole(VAULT_CONFIG_ROLE, address(borrowHandler));

        _setupCreditVault();

        excludeSender(address(cdpVault));
        excludeSender(address(borrowHandler));

        vm.label({account: address(cdpVault), newLabel: "CDPVault"});
        vm.label({
            account: address(borrowHandler),
            newLabel: "BorrowHandler"
        });

        (bytes4[] memory selectors, ) = borrowHandler.getTargetSelectors();
        targetSelector(
            FuzzSelector({
                addr: address(borrowHandler),
                selectors: selectors
            })
        );

        targetContract(address(borrowHandler));
    }

    // deploy a reserve vault and create credit for the borrow handler
    function _setupCreditVault() private {
        deal(
            address(token),
            address(borrowHandler),
            borrowHandler.collateralReserve() + borrowHandler.creditReserve()
        );

        CDPVault creditVault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: borrowHandler.creditReserve(), 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            baseRate: 1 ether
        });

        // increase the global debt ceiling
        if(initialGlobalDebtCeiling != uint256(type(int256).max)){
            setGlobalDebtCeiling(
                initialGlobalDebtCeiling + borrowHandler.creditReserve()
            );
        }
        
        vm.startPrank(address(borrowHandler));
        token.approve(address(creditVault), borrowHandler.creditReserve());
        creditVault.deposit(
            address(borrowHandler),
            borrowHandler.creditReserve()
        );
        int256 debt = int256(wmul(liquidationPrice(creditVault), borrowHandler.creditReserve()));
        creditVault.modifyCollateralAndDebt(
            address(borrowHandler),
            address(borrowHandler),
            address(borrowHandler),
            int256(borrowHandler.creditReserve()),
            debt
        );
        vm.stopPrank();
    }

    /// ======== CDPVault Invariant Tests ======== ///

    function invariant_CDPVault_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_A(cdpVault, borrowHandler);
    }

    function invariant_CDPVault_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_B(cdpVault, borrowHandler);
    }

    function invariant_CDPVault_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_CDPVault_C(cdpVault, borrowHandler);
    }

    /// ======== Interest Rate Model Invariant Tests ======== ///

    function invariant_IRM_A() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_A(cdpVault);
    }

    function invariant_IRM_B() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_B(borrowHandler);
    }

    function invariant_IRM_C() external useCurrentTimestamp printReport(borrowHandler) {
        assert_invariant_IRM_C(cdpVault, borrowHandler);
    }
}
