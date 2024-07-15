// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase, ERC20PresetMinterPauser} from "../TestBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IOracle} from "../../interfaces/IOracle.sol";
import {ICDPVaultBase} from "../../interfaces/ICDPVault.sol";
import {CDPVaultConstants, CDPVaultConfig} from "../../interfaces/ICDPVault.sol";
import {IPermission} from "../../interfaces/IPermission.sol";

import {WAD, wmul, wdiv, wpow, toInt256} from "../../utils/Math.sol";
import {CDPVault, VAULT_CONFIG_ROLE} from "../../CDPVault.sol";
import {console} from "forge-std/console.sol";

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

contract CDPVaultWrapper is CDPVault {
    constructor(CDPVaultConstants memory constants, CDPVaultConfig memory config) CDPVault(constants, config) {}
}

contract PositionOwner {
    constructor(IPermission vault) {
        // Allow deployer to modify Position
        vault.modifyPermission(msg.sender, true);
    }
}

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
