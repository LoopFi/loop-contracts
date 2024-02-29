// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {CDPVaultHandler} from "./handlers/CDPVaultHandler.sol";
import {CDPVaultWrapper} from "./CDPVaultWrapper.sol";

/// @title CDPVaultInvariantTest
/// @notice CDPVault invariant tests 
contract CDPVaultInvariantTest is InvariantTestBase{

    CDPVaultWrapper internal vault;
    CDPVaultHandler internal vaultHandler;

    /// ======== Setup ======== ///

    function setUp() public override virtual{
        super.setUp();
        
        vault = createCDPVaultWrapper({
            token_: token, 
            debtCeiling: initialGlobalDebtCeiling, 
            debtFloor: 100 ether, 
            liquidationRatio: 1.25 ether, 
            liquidationPenalty: 1.0 ether,
            liquidationDiscount: 1.0 ether, 
            baseRate: BASE_RATE_1_005
        });
        
        vaultHandler = new CDPVaultHandler(this, vault, new GhostVariableStorage());
        cdm.grantRole(keccak256("ACCOUNT_CONFIG_ROLE"), address(vaultHandler));

        excludeSender(address(vault));
        excludeSender(address(vaultHandler));

        vm.label({ account: address(vault), newLabel: "CDPVault" });
        vm.label({ account: address(vaultHandler), newLabel: "CDPVaultHandler" });

        deal(address(token), address(vaultHandler), vaultHandler.tokenReserve());
        // setup CDPVault selectors 
        (bytes4[] memory selectors, ) = vaultHandler.getTargetSelectors();
        targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: selectors}));

        targetContract(address(vaultHandler));
    }

    /// ======== CDM Invariant Tests ======== ///

    function invariant_CDM_A() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_A(); }
    function invariant_CDM_B() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_B(); }
    function invariant_CDM_C() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_C(vaultHandler); }
    function invariant_CDM_D() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_D(vaultHandler); }
    function invariant_CDM_E() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDM_E(vaultHandler); }

    /// ======== CDPVault Invariant Tests ======== ///
    function invariant_CDPVault_A() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_A(vault, vaultHandler); }
    function invariant_CDPVault_B() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_B(vault, vaultHandler); }
    function invariant_CDPVault_C() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_C(vault, vaultHandler); }
    function invariant_CDPVault_D() external useCurrentTimestamp printReport(vaultHandler) { assert_invariant_CDPVault_D(vault, vaultHandler); }
}