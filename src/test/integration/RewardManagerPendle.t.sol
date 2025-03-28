// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {Permission} from "../../utils/Permission.sol";
import {toInt256, WAD} from "../../utils/Math.sol";

import {CDPVault} from "../../CDPVault.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {BaseAction} from "../../proxy/BaseAction.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PositionAction, CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {PositionAction20} from "../../proxy/PositionAction20.sol";

import {TokenInput, LimitOrderData} from "pendle/interfaces/IPAllActionTypeV3.sol";
import {ApproxParams} from "pendle/interfaces/IPAllActionTypeV3.sol";
import {RewardManager} from "src/pendle-rewards/RewardManager.sol";
import {console} from "forge-std/console.sol";

interface IPendleMarketV3 {
    function redeemRewards(address user) external returns (uint256[] memory rewardsOut);

    function getRewardTokens() external view returns (address[] memory);

    function balanceOf(address account) external view returns (uint256);

    function userReward(address token, address user) external view returns (uint256 index, uint256 accrued);

    function lastRewardBlock() external view returns (uint256);

    function activeBalance(address user) external view returns (uint256);
}

contract RewardManagerPendleTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    PRBProxy userProxy2;
    address user;
    address user2;
    uint256 constant userPk = 0x12341234;
    uint256 constant userPk2 = 0x12341235;
    // cdp vaults
    CDPVault pendleVault_STETH;
    CDPVault pendleVault_weETH;

    // actions
    PositionAction20 positionAction;

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    address PENDLE_LP_ETHERFI = 0xF32e58F92e60f4b0A37A69b95d642A471365EAe8; // Ether.fi PT/SY
    address pendleOwner = 0x1FcCC097db89A86Bfc474A1028F93958295b1Fb7;
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    RewardManager rewardManager;
    address pendleToken = 0x808507121B80c02388fAd14726482e061B8da827;
    IPendleMarketV3 pendleStEth = IPendleMarketV3(address(PENDLE_LP_STETH));
    address pendleHolder = 0xa3A7B6F88361F48403514059F1F16C8E78d60EeC;

    function setUp() public virtual override {
        usePatchedDeal = true;
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        pendleVault_STETH = createCDPVault(
            PENDLE_LP_STETH, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        pendleVault_weETH = createCDPVault(
            ERC20(PENDLE_LP_ETHERFI), // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        createGaugeAndSetGauge(address(pendleVault_STETH), address(PENDLE_LP_STETH));
        createGaugeAndSetGauge(address(pendleVault_weETH), address(PENDLE_LP_ETHERFI));

        // RewardManager
        rewardManager = new RewardManager(
            address(pendleVault_STETH),
            address(PENDLE_LP_STETH),
            address(prbProxyRegistry)
        );
        pendleVault_STETH.setParameter("rewardManager", address(rewardManager));
        // configure oracle spot prices
        oracle.updateSpot(address(PENDLE_LP_STETH), 3500 ether);
        oracle.updateSpot(address(PENDLE_LP_ETHERFI), 3500 ether);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        user2 = vm.addr(0x12341235);
        userProxy2 = PRBProxy(payable(address(prbProxyRegistry.deployFor(user2))));
        // deploy position actions
        positionAction = new PositionAction20(
            address(flashlender),
            address(swapAction),
            address(poolAction),
            address(vaultRegistry),
            address(mockWETH)
        );

        vm.label(user, "user");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(PENDLE_LP_STETH), "PENDLE_LP_STETH");
        vm.label(address(PENDLE_LP_ETHERFI), "PENDLE_LP_ETHERFI");
        vm.label(address(pendleVault_STETH), "pendleVault_STETH");
        vm.label(address(pendleVault_weETH), "pendleVault_weETH");
        vm.label(address(positionAction), "positionAction");
    }

    function test_deploy_pendle_position_action() public {
        assertTrue(address(positionAction) != address(0));
    }

    function test_deposit_Pendle_LP_stETH_1_week_time_reward() public {
        uint256 depositAmount = 997 ether;

        (uint256 index, uint256 accrued) = pendleStEth.userReward(pendleToken, address(pendleVault_STETH));
        assertEq(index, 0);
        assertEq(accrued, 0);

        _deposit(userProxy, address(pendleVault_STETH), depositAmount);

        (index, accrued) = pendleStEth.userReward(pendleToken, address(pendleVault_STETH));
        assertGt(index, 0);
        assertEq(accrued, 0);

        (uint256 collateral, uint256 normalDebt, , , , ) = pendleVault_STETH.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);

        // check reward
        vm.prank(pendleHolder);
        ERC20(pendleToken).transfer(address(pendleStEth), 10000 ether);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 150);

        uint256 index2;
        (index2, accrued) = pendleStEth.userReward(pendleToken, address(pendleVault_STETH));
        assertEq(index, index2);
        assertEq(accrued, 0);

        assertEq(ERC20(pendleToken).balanceOf(address(pendleVault_STETH)), 0);

        pendleStEth.redeemRewards(address(pendleVault_STETH));

        assertGt(ERC20(pendleToken).balanceOf(address(pendleVault_STETH)), 0);

        pendleVault_STETH.getRewards(address(userProxy));
        assertGt(ERC20(pendleToken).balanceOf(address(user)), 0);
        assertEq(ERC20(pendleToken).balanceOf(address(pendleVault_STETH)), 0);
    }

    function test_deposit_from_proxy_collateralizer_PENDLE() public {
        uint256 depositAmount = 100 ether;

        vm.prank(pendleLP_STETH_Holder);
        PENDLE_LP_STETH.transfer(address(userProxy), depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH),
            amount: depositAmount,
            collateralizer: address(userProxy),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(pendleVault_STETH),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt, , , , ) = pendleVault_STETH.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_and_withdraw_from_user_PENDLE() public {
        uint256 depositAmount = 100 ether;

        vm.prank(pendleLP_STETH_Holder);
        PENDLE_LP_STETH.transfer(address(this), depositAmount);

        PENDLE_LP_STETH.approve(address(pendleVault_STETH), depositAmount);

        pendleVault_STETH.modifyCollateralAndDebt(address(this), address(this), address(this), int(depositAmount), 0);

        (uint256 collateral, uint256 normalDebt, , , , ) = pendleVault_STETH.positions(address(this));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);

        // check reward
        vm.prank(pendleHolder);
        ERC20(pendleToken).transfer(address(pendleStEth), 10000 ether);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 150);

        pendleVault_STETH.modifyCollateralAndDebt(address(this), address(this), address(this), -int(depositAmount), 0);
    }

    function test_withdraw_PENDLE() public {
        // deposit PENDLE_STETH to vault
        uint256 initialDeposit = 997 ether;
        _deposit(userProxy, address(pendleVault_STETH), initialDeposit);

        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH),
            amount: initialDeposit,
            collateralizer: address(user),
            auxSwap: auxSwap,
            minAmountOut: 0
        });

        // check reward
        vm.prank(pendleHolder);
        ERC20(pendleToken).transfer(address(pendleStEth), 10000 ether);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 150);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(pendleVault_STETH),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt, , , , ) = pendleVault_STETH.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        _deposit(userProxy, address(pendleVault_STETH), initialDeposit);

        // check reward
        vm.prank(pendleHolder);
        ERC20(pendleToken).transfer(address(pendleStEth), 10000 ether);

        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 800);

        uint256 pendleBalanceBefore = ERC20(pendleToken).balanceOf(address(user));
        assertGt(pendleBalanceBefore, 0);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(pendleVault_STETH),
                collateralParams
            )
        );

        assertGt(ERC20(pendleToken).balanceOf(address(user)), pendleBalanceBefore);
        assertEq(ERC20(pendleToken).balanceOf(address(userProxy)), 0);
        assertEq(ERC20(pendleToken).balanceOf(address(pendleVault_STETH)), 0);
    }

    function test_withdraw_PENDLE_2_users_simultaneously() public {
        // deposit PENDLE_STETH to vault
        uint256 initialDeposit = 997 ether;
        _deposit(userProxy, address(pendleVault_STETH), initialDeposit);
        _deposit(userProxy2, address(pendleVault_STETH), initialDeposit);
        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH),
            amount: initialDeposit,
            collateralizer: address(user),
            auxSwap: auxSwap,
            minAmountOut: 0
        });

        // check reward
        vm.prank(pendleHolder);
        ERC20(pendleToken).transfer(address(pendleStEth), 10000 ether);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 150);

        assertEq(ERC20(pendleToken).balanceOf(address(user)), 0);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(pendleVault_STETH),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt, , , , ) = pendleVault_STETH.positions(address(userProxy));
        assertEq(collateral, 0, "collateral not zero");
        assertEq(normalDebt, 0, "debt not zero");

        assertGt(ERC20(pendleToken).balanceOf(address(user)), 0);
        assertEq(ERC20(pendleToken).balanceOf(address(userProxy)), 0);

        // Some pendle reward is left in the vault for other users
        assertGt(ERC20(pendleToken).balanceOf(address(pendleVault_STETH)), 0);

        // check reward
        vm.prank(pendleHolder);
        ERC20(pendleToken).transfer(address(pendleStEth), 0.0011 ether);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 150);

        assertEq(ERC20(pendleToken).balanceOf(address(user2)), 0);

        collateralParams.collateralizer = address(user2);
        vm.prank(user2);
        userProxy2.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy2), // user proxy is the position
                address(pendleVault_STETH),
                collateralParams
            )
        );

        uint256 pendleBalAfter = ERC20(pendleToken).balanceOf(address(user2));
        assertGt(pendleBalAfter, 0);
        assertEq(ERC20(pendleToken).balanceOf(address(userProxy2)), 0);
        assertEq(ERC20(pendleToken).balanceOf(address(pendleVault_STETH)), 0);

        pendleVault_STETH.getRewards(address(userProxy2));
        assertEq(ERC20(pendleToken).balanceOf(address(user2)), pendleBalAfter);
        assertEq(ERC20(pendleToken).balanceOf(address(userProxy2)), 0);
        assertEq(ERC20(pendleToken).balanceOf(address(pendleVault_STETH)), 0);
    }

    function test_borrow_PENDLE() public {
        // deposit pendleVault_STETH to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(pendleVault_STETH), initialDeposit);

        // borrow against deposit
        uint256 borrowAmount = 500 * 1 ether;

        // build borrow params
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: emptySwap // no entry swap
        });

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(userProxy), // user proxy is the position
                address(pendleVault_STETH),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt, , , , ) = pendleVault_STETH.positions(address(userProxy));
        assertEq(collateral, initialDeposit);
        assertEq(normalDebt, borrowAmount);
    }

    function test_depositAndBorrow_PENDLE() public {
        // accure interest
        uint256 depositAmount = 10_000 ether;
        uint256 borrowAmount = 5_000 ether;
        _depositAndBorrow(userProxy, address(pendleVault_STETH), depositAmount, borrowAmount);

        vm.warp(block.timestamp + 10 * 365 days);

        (uint256 collateral, uint256 debt, , , , ) = pendleVault_STETH.positions(address(userProxy));

        assertEq(collateral, depositAmount);

        assertGe(debt, borrowAmount);

        // assert that debt is minted to the user
        assertEq(underlyingToken.balanceOf(user), borrowAmount);
    }

    // REPAY TESTS
    function test_repay_PENDLE() public {
        uint256 depositAmount = 1_000 * 1 ether; // LP_STETH
        uint256 borrowAmount = 500 * 1 ether; // stablecoin
        _depositAndBorrow(userProxy, address(pendleVault_STETH), depositAmount, borrowAmount);

        // build repay params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: auxSwap // no entry swap
        });

        vm.startPrank(user);
        underlyingToken.approve(address(userProxy), borrowAmount);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.repay.selector,
                address(userProxy), // user proxy is the position
                address(pendleVault_STETH),
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 debt, , , , ) = pendleVault_STETH.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(underlyingToken.balanceOf(user), 0);
        assertEq(underlyingToken.balanceOf(address(userProxy)), 0);
    }

    function test_withdrawAndRepay_PENDLE() public {
        uint256 depositAmount = 5_000 * 1 ether;
        uint256 borrowAmount = 2_500 * 1 ether;

        // deposit and borrow
        _depositAndBorrow(userProxy, address(pendleVault_STETH), depositAmount, borrowAmount);

        // build withdraw and repay params
        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        {
            collateralParams = CollateralParams({
                targetToken: address(PENDLE_LP_STETH),
                amount: depositAmount,
                collateralizer: user,
                auxSwap: emptySwap,
                minAmountOut: 0
            });
            creditParams = CreditParams({amount: borrowAmount, creditor: user, auxSwap: emptySwap});
        }

        vm.startPrank(user);
        underlyingToken.approve(address(userProxy), borrowAmount);

        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdrawAndRepay.selector,
                address(userProxy), // user proxy is the position
                address(pendleVault_STETH),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 debt, , , , ) = pendleVault_STETH.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(underlyingToken.balanceOf(user), 0);
        assertEq(PENDLE_LP_STETH.balanceOf(user), depositAmount);
    }

    // MULTISEND

    function test_multisend_simple_delegatecall_PENDLE() public {
        uint256 depositAmount = 1_000 ether;
        uint256 borrowAmount = 500 ether;

        deal(address(PENDLE_LP_STETH), address(userProxy), depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH),
            amount: depositAmount,
            collateralizer: address(userProxy),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: address(userProxy),
            auxSwap: emptySwap
        });

        address[] memory targets = new address[](2);
        targets[0] = address(positionAction);
        targets[1] = address(pendleVault_STETH);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            positionAction.depositAndBorrow.selector,
            address(userProxy),
            address(pendleVault_STETH),
            collateralParams,
            creditParams,
            emptyPermitParams
        );
        data[1] = abi.encodeWithSelector(
            CDPVault.modifyCollateralAndDebt.selector,
            address(userProxy),
            address(userProxy),
            address(userProxy),
            0,
            0
        );

        bool[] memory delegateCall = new bool[](2);
        delegateCall[0] = true;
        delegateCall[1] = false;

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(positionAction.multisend.selector, targets, data, delegateCall)
        );

        (uint256 collateral, uint256 debt, , , , ) = pendleVault_STETH.positions(address(userProxy));
        assertEq(collateral, depositAmount);
        assertEq(debt, borrowAmount);
    }

    function test_multisend_deposit_PENDLE() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(PENDLE_LP_STETH), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        vm.prank(user);
        PENDLE_LP_STETH.approve(address(userProxy), depositAmount);

        address[] memory targets = new address[](2);
        targets[0] = address(positionAction);
        targets[1] = address(pendleVault_STETH);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            positionAction.deposit.selector,
            address(userProxy),
            pendleVault_STETH,
            collateralParams,
            emptyPermitParams
        );
        data[1] = abi.encodeWithSelector(
            pendleVault_STETH.modifyCollateralAndDebt.selector,
            address(userProxy),
            address(userProxy),
            address(userProxy),
            0,
            toInt256(100 ether)
        );

        bool[] memory delegateCall = new bool[](2);
        delegateCall[0] = true;
        delegateCall[1] = false;

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(positionAction.multisend.selector, targets, data, delegateCall)
        );

        (uint256 collateral, uint256 normalDebt, , , , ) = pendleVault_STETH.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 100 ether);
    }

    // HELPER FUNCTIONS

    function _deposit(PRBProxy proxy, address vault, uint256 amount) internal {
        CDPVault cdpVault = CDPVault(vault);
        address token = address(cdpVault.token());

        // mint vault token to position
        deal(token, address(proxy), amount);

        // build collateral params
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: token,
            amount: amount,
            collateralizer: address(proxy),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        vm.prank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(proxy), // user proxy is the position
                vault,
                collateralParams,
                emptyPermitParams
            )
        );
    }

    function _borrow(PRBProxy proxy, address vault, uint256 borrowAmount) internal {
        // build borrow params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: address(proxy),
            auxSwap: auxSwap // no entry swap
        });

        vm.prank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.borrow.selector,
                address(proxy), // user proxy is the position
                vault,
                creditParams
            )
        );
    }

    function _depositAndBorrow(PRBProxy proxy, address vault, uint256 depositAmount, uint256 borrowAmount) internal {
        CDPVault cdpVault = CDPVault(vault);
        address token = address(cdpVault.token());

        // mint vault token to position
        deal(token, address(proxy), depositAmount);

        // build add collateral params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: token,
            amount: depositAmount,
            collateralizer: address(proxy),
            auxSwap: auxSwap, // no entry swap
            minAmountOut: 0
        });
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: proxy.owner(),
            auxSwap: auxSwap // no exit swap
        });

        vm.startPrank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.depositAndBorrow.selector,
                address(proxy), // user proxy is the position
                vault,
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 19356381;
    }
}
