// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase, ERC20PresetMinterPauser, PoolV3} from "../TestBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IOracle} from "../../interfaces/IOracle.sol";
import {ICDPVaultBase} from "../../interfaces/ICDPVault.sol";
import {CDPVaultConstants, CDPVaultConfig} from "../../interfaces/ICDPVault.sol";
import {IPermission} from "../../interfaces/IPermission.sol";

import {WAD, wmul, wdiv, wpow, toInt256} from "../../utils/Math.sol";
import {CDPVault, VAULT_CONFIG_ROLE} from "../../CDPVault.sol";
import {console} from "forge-std/console.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract MockTokenScaled is ERC20PresetMinterPauser {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20PresetMinterPauser(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
import {CDPVault, VAULT_CONFIG_ROLE} from "../../CDPVault.sol";
import {console} from "forge-std/console.sol";

contract PoolV3Test is TestBase {
    address user1 = address(0x1);
    address user2 = address(0x2);

    function test_default_locked() public {
        assertTrue(liquidityPool.locked());
    }

    function test_deposit() public {
        // Setup
        mockWETH.mint(user1, 1000 ether);
        mockWETH.mint(user2, 1000 ether);
        vm.prank(user1);
        mockWETH.approve(address(liquidityPool), 1000 ether);
        vm.prank(user2);
        mockWETH.approve(address(liquidityPool), 1000 ether);

        // Deposit
        vm.prank(user1);
        liquidityPool.deposit(1000 ether, user1);

        vm.prank(user2);
        liquidityPool.deposit(1000 ether, user2);

        assertEq(liquidityPool.balanceOf(user1), 1000 ether);
        assertEq(liquidityPool.balanceOf(user2), 1000 ether);
    }

    function test_redeem_Fails_if_locked() public {
        test_deposit();
        vm.prank(user1);
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.redeem(1000 ether, user1, user1);

        vm.prank(user2);
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.redeem(1000 ether, user1, user1);

        uint256 totalSupply = liquidityPool.totalSupply();
        vm.prank(address(this));
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.redeem(totalSupply - 2000 ether, address(this), address(this));
    }

    function test_withdraw_Fails_if_locked() public {
        test_deposit();
        vm.prank(user1);
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.withdraw(1000 ether, user1, user1);

        vm.prank(user2);
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.withdraw(1000 ether, user1, user1);

        uint256 totalSupply = liquidityPool.totalSupply();
        vm.prank(address(this));
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.withdraw(totalSupply - 2000 ether, address(this), address(this));
    }

    function test_redeem_if_not_locked() public {
        test_deposit();
        liquidityPool.setLock(false);

        vm.prank(user1);
        liquidityPool.redeem(1000 ether, user1, user1);

        vm.prank(user2);
        liquidityPool.redeem(1000 ether, user2, user2);

        uint256 totalSupply = liquidityPool.totalSupply();
        vm.prank(address(this));
        liquidityPool.redeem(totalSupply, address(this), address(this));

        assertEq(liquidityPool.balanceOf(user1), 0);
        assertEq(liquidityPool.balanceOf(user2), 0);
        assertEq(liquidityPool.totalSupply(), 0);
    }

    function test_withdraw_if_not_locked() public {
        test_deposit();
        liquidityPool.setLock(false);

        vm.prank(user1);
        liquidityPool.withdraw(1000 ether, user1, user1);

        vm.prank(user2);
        liquidityPool.withdraw(1000 ether, user2, user2);

        uint256 totalSupply = liquidityPool.totalSupply();
        vm.prank(address(this));
        liquidityPool.withdraw(totalSupply, address(this), address(this));

        assertEq(liquidityPool.balanceOf(user1), 0);
        assertEq(liquidityPool.balanceOf(user2), 0);
        assertEq(liquidityPool.totalSupply(), 0);
    }

    function test_withdraw_or_redeem_if_allowed_when_locked() public {
        test_deposit();
        liquidityPool.setAllowed(user1, true);
        liquidityPool.setAllowed(address(this), true);

        vm.prank(user1);
        liquidityPool.redeem(500 ether, user1, user1);
        assertEq(liquidityPool.balanceOf(user1), 500 ether);

        vm.prank(user1);
        liquidityPool.withdraw(500 ether, user1, user1);
        assertEq(liquidityPool.balanceOf(user1), 0);

        vm.prank(user2);
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.redeem(1000 ether, user2, user2);

        vm.prank(user2);
        vm.expectRevert(PoolV3.PoolV3LockedException.selector);
        liquidityPool.withdraw(1000 ether, user2, user2);
    }
}
