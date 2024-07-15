// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase, ERC20PresetMinterPauser} from "../TestBase.sol";

import {console} from "forge-std/console.sol";

contract StakingLPEthTest is TestBase {
    address user1 = address(0x23);
    address user2 = address(0x24);
    address user3 = address(0x25);

    function setUp() public override {
        super.setUp();
        liquidityPool.transfer(user1, 1000);
        liquidityPool.transfer(user2, 1000);
        liquidityPool.transfer(user3, 1000);
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
        uint256 amount = 1000;
        liquidityPool.transfer(address(stakingLpEth), amount);
    }

    function test_deposit_user1() public {
        vm.startPrank(user1);
        liquidityPool.approve(address(stakingLpEth), 1000);
        stakingLpEth.deposit(1000, user1);
        vm.stopPrank();
        assertEq(stakingLpEth.balanceOf(user1), 1000);
        assertEq(stakingLpEth.totalSupply(), 1000);
        assertEq(liquidityPool.balanceOf(address(stakingLpEth)), 1000);
        assertEq(liquidityPool.balanceOf(user1), 0);
    }

    function test_rewards_1_user() public {
        test_deposit_user1();
        _sendRewards();
        vm.startPrank(user1);
        stakingLpEth.approve(address(stakingLpEth), 1000);
        stakingLpEth.redeem(1000, user1, user1);
        assertApproxEqAbs(liquidityPool.balanceOf(user1), 2000, 1);
    }

    function test_deposit_2_users() public {
        test_deposit_user1();
        vm.startPrank(user2);
        liquidityPool.approve(address(stakingLpEth), 1000);
        stakingLpEth.deposit(1000, user2);
        vm.stopPrank();
        assertEq(stakingLpEth.balanceOf(user2), 1000);
    }

    function test_rewards_2_users() public {
        test_deposit_user1();
        _sendRewards();
        // User 2 deposits after some rewards are already present, receives less shares
        vm.startPrank(user2);
        liquidityPool.approve(address(stakingLpEth), 1000);
        stakingLpEth.deposit(1000, user2);
        vm.stopPrank();
        assertEq(stakingLpEth.balanceOf(user2), 500);

        _sendRewards();
        vm.startPrank(user1);
        stakingLpEth.approve(address(stakingLpEth), 1000);
        stakingLpEth.redeem(1000, user1, user1);
        vm.stopPrank();
        assertApproxEqAbs(liquidityPool.balanceOf(user1), 2666, 1);

        vm.startPrank(user2);
        stakingLpEth.approve(address(stakingLpEth), 500);
        stakingLpEth.redeem(500, user2, user2);
        vm.stopPrank();
        assertApproxEqAbs(liquidityPool.balanceOf(user2), 1333, 1);
    }
}
