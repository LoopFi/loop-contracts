// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {WAD} from "../../utils/Math.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";


import {PoolV3} from "../../PoolV3.sol";


contract PoolV3Test is IntegrationTestBase {
    using SafeERC20 for ERC20;


    function test_deploy() public {
        assertNotEq(address(liquidityPool), address(0));
    }

    function test_depositEth() public {
      uint256 balanceBefore = address(this).balance;
      uint256 poolBalanceBefore = WETH.balanceOf(address(liquidityPool));
      uint256 shares = liquidityPool.depositETH{value: 1 ether}(address(this));
      
      uint256 balanceAfter = address(this).balance;
      uint256 poolBalanceAfter = WETH.balanceOf(address(liquidityPool));

      assertEq(shares, 1 ether);
      assertEq(balanceBefore - balanceAfter, 1 ether);
      assertEq(poolBalanceAfter - poolBalanceBefore, 1 ether);
    }

    function test_depositEth_revertsIfNotEnoughEth() public {
      address depositor = address(0x123);

      deal(depositor, 0);
      vm.prank(depositor);
      vm.expectRevert();
      liquidityPool.depositETH{value: 1 ether}(address(this));

      deal(depositor, 1 ether);
      vm.prank(depositor);
      uint256 shares = liquidityPool.depositETH{value: 1 ether}(address(this));
      assertEq(shares, 1 ether);
    }

    function test_depositEth_revertsIfNoEthSent() public {
      vm.expectRevert(PoolV3.NoEthSent.selector);
      liquidityPool.depositETH{value: 0}(address(this));
    }
}
