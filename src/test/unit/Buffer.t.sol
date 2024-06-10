// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ICDM} from "../../interfaces/ICDM.sol";

import {CDM, getCredit, getDebt, getCreditLine} from "../../CDM.sol";
import {Buffer, CREDIT_MANAGER_ROLE} from "../../Buffer.sol";

contract BufferTest is Test {
    CDM cdm;
    Buffer buffer;
    address vault = makeAddr("vault");
    address me = address(this);

    uint256 globalDebtCeiling = 10_000 ether;

    uint256 initialVaultCeiling = 5_000 ether;
    uint256 initialVaultCredit = 1_000 ether;

    function setUp() public {
        cdm = new CDM(me, me, me);

        buffer = Buffer(
            address(
                new ERC1967Proxy(
                    address(new Buffer(ICDM(address(cdm)))),
                    abi.encodeWithSelector(Buffer.initialize.selector, me, me)
                )
            )
        );

        cdm.setParameter("globalDebtCeiling", globalDebtCeiling);

        // give test ability to generate debt
        cdm.setParameter(address(this), "debtCeiling", initialVaultCeiling);

        // set up buffer in cdm with initial credit
        cdm.setParameter(address(buffer), "debtCeiling", initialVaultCeiling);
        cdm.modifyBalance(address(this), address(buffer), initialVaultCredit);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _credit(address account) internal view returns (uint256) {
        (int256 balance, ) = cdm.accounts(account);
        return getCredit(balance);
    }

    function _debt(address account) internal view returns (uint256) {
        (int256 balance, ) = cdm.accounts(account);
        return getDebt(balance);
    }

    function _getCreditLine(address account) internal view returns (uint256) {
        (int256 balance, uint256 debtCeiling) = cdm.accounts(account);
        return getCreditLine(balance, debtCeiling);
    }

    function test_initialize_accounts(address admin, address manager) public {
        buffer = Buffer(
            address(
                new ERC1967Proxy(
                    address(new Buffer(ICDM(address(cdm)))),
                    abi.encodeWithSelector(Buffer.initialize.selector, admin, manager)
                )
            )
        );

        assertTrue(buffer.hasRole(CREDIT_MANAGER_ROLE, manager));

        assertTrue(buffer.hasRole(buffer.DEFAULT_ADMIN_ROLE(), admin));
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawCredit() public {
        buffer.withdrawCredit(vault, 100 ether);

        assertEq(_credit(address(buffer)), initialVaultCredit - 100 ether);
        assertEq(_credit(vault), 100 ether);
    }

    function test_fail_withdrawCredit_no_permission() public {
        address randomAddress = makeAddr("randomAddress");

        vm.expectRevert(_getOnlyRoleRevertMsg(randomAddress, keccak256("CREDIT_MANAGER_ROLE")));
        vm.prank(randomAddress);
        buffer.withdrawCredit(randomAddress, 1 ether);
    }

    function test_fail_withdrawCredit_zero_address() public {
        vm.expectRevert(Buffer.Buffer__withdrawCredit_zeroAddress.selector);
        buffer.withdrawCredit(address(0), 1 ether);
    }

    function _getOnlyRoleRevertMsg(address account, bytes32 role) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(account),
                " is missing role ",
                Strings.toHexString(uint256(role), 32)
            );
    }
}
