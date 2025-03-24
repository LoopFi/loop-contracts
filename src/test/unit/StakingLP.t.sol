// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase, ERC20PresetMinterPauser} from "../TestBase.sol";

import {console} from "forge-std/console.sol";
import {StakingLPEth} from "../../StakingLPEth.sol";

contract StakingLPEthTest is TestBase {
    address user1 = address(0x23);
    address user2 = address(0x24);
    address user3 = address(0x25);

    function setUp() public override {
        super.setUp();
        liquidityPool.transfer(user1, 0.1 ether);
        liquidityPool.transfer(user2, 0.1 ether);
        liquidityPool.transfer(user3, 0.1 ether);
        stakingLpEth.setCooldownDuration(0);
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_deploy() public {
        assertEq(stakingLpEth.decimals(), 18);
        assertEq(stakingLpEth.totalSupply(), 0);
        assertEq(stakingLpEth.asset(), address(liquidityPool));
        assertEq(stakingLpEth.name(), "StakingLPEth");
        assertEq(stakingLpEth.symbol(), "sLP-ETH");
    }

    function _sendRewards() private {
        uint256 amount = 0.1 ether;
        liquidityPool.transfer(address(stakingLpEth), amount);
    }

    function test_deposit_user1() public {
        vm.startPrank(user1);
        liquidityPool.approve(address(stakingLpEth), 0.1 ether);
        stakingLpEth.deposit(0.1 ether, user1);
        vm.stopPrank();
        assertEq(stakingLpEth.balanceOf(user1), 0.1 ether);
        assertEq(stakingLpEth.totalSupply(), 0.1 ether);
        assertEq(liquidityPool.balanceOf(address(stakingLpEth)), 0.1 ether);
        assertEq(liquidityPool.balanceOf(user1), 0);
    }

    function test_rewards_1_user() public {
        test_deposit_user1();
        _sendRewards();
        vm.startPrank(user1);
        stakingLpEth.approve(address(stakingLpEth), 0.1 ether);
        stakingLpEth.redeem(0.1 ether, user1, user1);
        assertApproxEqAbs(liquidityPool.balanceOf(user1), 0.2 ether, 1);
    }

    function test_deposit_2_users() public {
        test_deposit_user1();
        vm.startPrank(user2);
        liquidityPool.approve(address(stakingLpEth), 0.1 ether);
        stakingLpEth.deposit(0.1 ether, user2);
        vm.stopPrank();
        assertEq(stakingLpEth.balanceOf(user2), 0.1 ether);
    }

    function test_rewards_2_users() public {
        test_deposit_user1();
        _sendRewards();
        // User 2 deposits after some rewards are already present, receives less shares
        vm.startPrank(user2);
        liquidityPool.approve(address(stakingLpEth), 0.1 ether);
        stakingLpEth.deposit(0.1 ether, user2);
        vm.stopPrank();
        assertEq(stakingLpEth.balanceOf(user2), 0.05 ether);

        _sendRewards();
        vm.startPrank(user1);
        stakingLpEth.approve(address(stakingLpEth), 0.1 ether);
        stakingLpEth.redeem(0.1 ether, user1, user1);
        vm.stopPrank();
        assertApproxEqAbs(liquidityPool.balanceOf(user1), 0.266666666666666666 ether, 1);

        vm.startPrank(user2);
        stakingLpEth.approve(address(stakingLpEth), 0.05 ether);
        stakingLpEth.redeem(0.05 ether, user2, user2);
        vm.stopPrank();
        assertApproxEqAbs(liquidityPool.balanceOf(user2), 0.133333333333333333 ether, 1);
    }

    function test_cooldown_withdraw() public {
        stakingLpEth.setCooldownDuration(7 days);
        test_deposit_user1();
        _sendRewards();
        vm.startPrank(user1);
        stakingLpEth.cooldownShares(stakingLpEth.balanceOf(user1));
        vm.expectRevert(StakingLPEth.InvalidCooldown.selector);
        stakingLpEth.unstake(user1);
        vm.warp(block.timestamp + 7 days);
        stakingLpEth.unstake(user1);
        assertApproxEqAbs(liquidityPool.balanceOf(user1), 0.199999999999999999 ether, 1);
    }

    function test_cooldown_redeem() public {
        stakingLpEth.setCooldownDuration(7 days);
        test_deposit_user1();
        _sendRewards();
        vm.startPrank(user1);
        stakingLpEth.cooldownAssets(stakingLpEth.previewRedeem(stakingLpEth.balanceOf(user1)));
        vm.expectRevert(StakingLPEth.InvalidCooldown.selector);
        stakingLpEth.unstake(user1);
        vm.warp(block.timestamp + 7 days);
        stakingLpEth.unstake(user1);
        assertApproxEqAbs(liquidityPool.balanceOf(user1), 0.199999999999999999 ether, 1);
    }

    function test_addToWhitelist() public {
        address whitelistedUser = address(0x123);
        
        // Grant WHITELIST_ADMIN_ROLE to the test contract
        stakingLpEth.grantRole(stakingLpEth.WHITELIST_ADMIN_ROLE(), address(this));
        
        // Add user to whitelist
        stakingLpEth.addToWhitelist(whitelistedUser);
        
        // Verify user is whitelisted
        assertTrue(stakingLpEth.isWhitelisted(whitelistedUser));
    }

    function test_addToWhitelist_RevertWhenNotAdmin() public {
        address whitelistedUser = address(0x123);
        address nonAdmin = address(0x456);
        
        // Try to add to whitelist from non-admin account
        vm.prank(nonAdmin);
        vm.expectRevert();
        stakingLpEth.addToWhitelist(whitelistedUser);
    }

    function test_removeFromWhitelist() public {
        address whitelistedUser = address(0x123);
        
        // Grant WHITELIST_ADMIN_ROLE to the test contract
        stakingLpEth.grantRole(stakingLpEth.WHITELIST_ADMIN_ROLE(), address(this));
        
        // First add user to whitelist
        stakingLpEth.addToWhitelist(whitelistedUser);
        assertTrue(stakingLpEth.isWhitelisted(whitelistedUser));
        
        // Remove user from whitelist
        stakingLpEth.removeFromWhitelist(whitelistedUser);
        
        // Verify user is no longer whitelisted
        assertFalse(stakingLpEth.isWhitelisted(whitelistedUser));
    }

    function test_removeFromWhitelist_RevertWhenNotAdmin() public {
        address whitelistedUser = address(0x123);
        address nonAdmin = address(0x456);
        
        // Grant WHITELIST_ADMIN_ROLE to the test contract and add user to whitelist
        stakingLpEth.grantRole(stakingLpEth.WHITELIST_ADMIN_ROLE(), address(this));
        stakingLpEth.addToWhitelist(whitelistedUser);
        
        // Try to remove from whitelist using non-admin account
        vm.prank(nonAdmin);
        vm.expectRevert();
        stakingLpEth.removeFromWhitelist(whitelistedUser);
    }

    function test_unstake_whitelisted() public {
        stakingLpEth.setCooldownDuration(7 days);
        address whitelistedUser = address(0x123);
        uint256 depositAmount = 1e18;
        
        // Setup whitelist
        stakingLpEth.grantRole(stakingLpEth.WHITELIST_ADMIN_ROLE(), address(this));
        stakingLpEth.addToWhitelist(whitelistedUser);
        
        // Setup initial state - deposit and start cooldown
        deal(address(liquidityPool), whitelistedUser, depositAmount);
        vm.startPrank(whitelistedUser);
        liquidityPool.approve(address(stakingLpEth), depositAmount);
        stakingLpEth.deposit(depositAmount, whitelistedUser);
        
        uint256 shares = stakingLpEth.cooldownAssets(depositAmount);
        
        // Try to unstake immediately (should work for whitelisted user)
        stakingLpEth.unstake(whitelistedUser);
        vm.stopPrank();
        
        // Verify unstake was successful
        assertEq(liquidityPool.balanceOf(whitelistedUser), depositAmount);
        assertEq(stakingLpEth.balanceOf(whitelistedUser), 0);
    }

    function test_unstake_revertOnCooldownIfNotWhitelisted() public {
        stakingLpEth.setCooldownDuration(7 days);
        address nonWhitelistedUser = address(0x123);
        uint256 depositAmount = 1e18;
        
        // Setup initial state - deposit and start cooldown
        deal(address(liquidityPool), nonWhitelistedUser, depositAmount);
        vm.startPrank(nonWhitelistedUser);
        liquidityPool.approve(address(stakingLpEth), depositAmount);
        stakingLpEth.deposit(depositAmount, nonWhitelistedUser);
        
        uint256 shares = stakingLpEth.cooldownAssets(depositAmount);
        
        // Try to unstake immediately (should fail for non-whitelisted user)
        vm.expectRevert(StakingLPEth.InvalidCooldown.selector);
        stakingLpEth.unstake(nonWhitelistedUser);
        vm.stopPrank();
    }

    function test_unstake_revertOnCooldownIfRemovedFromWhitelist() public {
        stakingLpEth.setCooldownDuration(7 days);
        address user = address(0x123);
        uint256 depositAmount = 1e18;
        
        // Setup whitelist
        stakingLpEth.grantRole(stakingLpEth.WHITELIST_ADMIN_ROLE(), address(this));
        stakingLpEth.addToWhitelist(user);
        
        // Setup initial state
        deal(address(liquidityPool), user, depositAmount);
        vm.startPrank(user);
        liquidityPool.approve(address(stakingLpEth), depositAmount);
        stakingLpEth.deposit(depositAmount, user);
        
        uint256 shares = stakingLpEth.cooldownAssets(depositAmount);
        
        // Remove from whitelist
        vm.stopPrank();
        stakingLpEth.removeFromWhitelist(user);
        
        // Try to unstake (should fail now)
        vm.prank(user);
        vm.expectRevert(StakingLPEth.InvalidCooldown.selector);
        stakingLpEth.unstake(user);
    }
}
