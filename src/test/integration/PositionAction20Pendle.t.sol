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
import {ApproxParams} from "pendle/router/base/MarketApproxLib.sol";

contract PositionAction20PendleTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

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
        // configure oracle spot prices
        oracle.updateSpot(address(PENDLE_LP_STETH), 3500 ether);
        oracle.updateSpot(address(PENDLE_LP_ETHERFI), 3500 ether);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        // deploy position actions
        positionAction = new PositionAction20(address(flashlender), address(swapAction), address(poolAction));

        vm.label(user, "user");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(pendleVault_STETH), "pendleVault_STETH");
        vm.label(address(pendleVault_weETH), "pendleVault_weETH");
        vm.label(address(positionAction), "positionAction");
    }


    // function test_deposit_Pendle_LP_stETH() public {
    //     uint256 depositAmount = 100 ether;

    //     vm.prank(pendleLP_STETH_Holder);
    //     PENDLE_LP_STETH.transfer(user, depositAmount);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(PENDLE_LP_STETH),
    //         amount: depositAmount,
    //         collateralizer: address(user),
    //         auxSwap: emptySwap
    //     });

    //     vm.prank(user);
    //     PENDLE_LP_STETH.approve(address(userProxy), depositAmount);


    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.deposit.selector,
    //             address(userProxy),
    //             address(pendleVault_STETH),
    //             collateralParams,
    //             emptyPermitParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));

    //     assertEq(collateral, depositAmount);
    //     assertEq(normalDebt, 0);
    // }


    // // function test_deposit_PENDLE_vault_with_entry_from_ETH() public {
    // //     uint256 depositAmount = 5 ether;
    // //    // uint256 amountOutMin = depositAmount * 1e12 * 98 / 100; // convert 6 decimals to 18 and add 1% slippage

    // //    // deal(address(USDC), user, depositAmount);
    // //     deal(user, 10 ether);

    // //     SwapParams memory swapParams;
    // //     PermitParams memory permitParams;

    // //     ApproxParams memory approxParams;
    // //     TokenInput memory tokenInput;
    // //     LimitOrderData memory limitOrderData;

    // //     approxParams = ApproxParams({
    // //         guessMin: 0,
    // //         guessMax: 15519288115338392367,
    // //         guessOffchain: 0,
    // //         maxIteration: 12,
    // //         eps: 10000000000000000
    // //     });

    // //     tokenInput.tokenIn = address(0);
    // //     tokenInput.netTokenIn = depositAmount;
        
    // //     swapParams = SwapParams({
    // //         swapProtocol: SwapProtocol.PENDLE_IN,
    // //         swapType: SwapType.EXACT_IN,
    // //         assetIn : address(0),
    // //         amount: tokenInput.netTokenIn,
    // //         limit: 0,
    // //         recipient: address(userProxy),
    // //         deadline: 0,
    // //         args: abi.encode(
    // //             PENDLE_LP_ETHERFI,
    // //             approxParams,
    // //             tokenInput,
    // //             limitOrderData
    // //         )
    // //     });

        
    // //     // build increase collateral params
    // //     // bytes32[] memory poolIds = new bytes32[](1);
    // //     // poolIds[0] = stablePoolId;

    // //     // address[] memory assets = new address[](2);
    // //     // assets[0] = address(USDC);
    // //     // assets[1] = address(DAI);

    // //     CollateralParams memory collateralParams = CollateralParams({
    // //         targetToken: PENDLE_LP_ETHERFI,
    // //         amount: 0, // not used for swaps
    // //         collateralizer: address(user),
    // //         auxSwap: swapParams
    // //     });

    // //     //    uint256 expectedCollateral = _simulateBalancerSwap(collateralParams.auxSwap);

    // //     vm.prank(user);
    // //     USDC.approve(address(userProxy), depositAmount);


    // //     vm.prank(user);
    // //     userProxy.execute{value: 5 ether}(
    // //         address(positionAction),
    // //         abi.encodeWithSelector(
    // //             positionAction.deposit.selector,
    // //             address(userProxy),
    // //             address(pendleVault_STETH),
    // //             collateralParams,
    // //             emptyPermitParams
    // //         )
    // //     );

    // //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));

    // //     assertGt(collateral, 0);
    // //     assertEq(normalDebt, 0);
    // // }


    // function test_deposit_from_proxy_collateralizer_PENDLE() public {
    //     uint256 depositAmount = 100 ether;

    //     vm.prank(pendleLP_STETH_Holder);
    //     PENDLE_LP_STETH.transfer(address(userProxy), depositAmount);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(PENDLE_LP_STETH),
    //         amount: depositAmount,
    //         collateralizer: address(userProxy),
    //         auxSwap: emptySwap
    //     });


    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.deposit.selector,
    //             address(userProxy),
    //             address(pendleVault_STETH),
    //             collateralParams,
    //             emptyPermitParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));

    //     assertEq(collateral, depositAmount);
    //     assertEq(normalDebt, 0);
    // }

    // function test_deposit_to_an_unrelated_position_PENDLE() public {

    //     // create 2nd position
    //     address alice = vm.addr(0x45674567);
    //     PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));

    //     uint256 depositAmount = 100 ether;

    //     vm.prank(pendleLP_STETH_Holder);
    //     PENDLE_LP_STETH.transfer(address(userProxy), depositAmount);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(PENDLE_LP_STETH),
    //         amount: depositAmount,
    //         collateralizer: address(userProxy),
    //         auxSwap: emptySwap
    //     });


    //     vm.prank(user);
    //     PENDLE_LP_STETH.approve(address(userProxy), depositAmount);

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.deposit.selector,
    //             address(aliceProxy),
    //             address(pendleVault_STETH),
    //             collateralParams,
    //             emptyPermitParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(aliceProxy));

    //     assertEq(collateral, depositAmount);
    //     assertEq(normalDebt, 0);
    // }

    // function test_withdraw_PENDLE() public {
    //     // deposit PENDLE_STETH to vault
    //     uint256 initialDeposit = 1_000 ether;
    //     _deposit(userProxy, address(pendleVault_STETH), initialDeposit);

    //     // build withdraw params
    //     SwapParams memory auxSwap;
    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(PENDLE_LP_STETH),
    //         amount: initialDeposit,
    //         collateralizer: address(user),
    //         auxSwap: auxSwap
    //     });

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.withdraw.selector,
    //             address(userProxy), // user proxy is the position
    //             address(pendleVault_STETH),
    //             collateralParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));
    //     assertEq(collateral, 0);
    //     assertEq(normalDebt, 0);

    //     (int256 balance,) = cdm.accounts(address(userProxy));
    //     assertEq(balance, 0);
    // }

    // function test_borrow_PENDLE() public {
    //     // deposit pendleVault_STETH to vault
    //     uint256 initialDeposit = 1_000 ether;
    //     _deposit(userProxy, address(pendleVault_STETH), initialDeposit);

    //     // borrow against deposit
    //     uint256 borrowAmount = 500*1 ether;

    //     // build borrow params
    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: user,
    //         auxSwap: emptySwap // no entry swap
    //     });

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.borrow.selector,
    //             address(userProxy), // user proxy is the position
    //             address(pendleVault_STETH),
    //             creditParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));
    //     assertEq(collateral, initialDeposit);
    //     assertEq(normalDebt, borrowAmount);

    //     (int256 balance,) = cdm.accounts(address(userProxy));
    //     assertEq(balance, 0);
    //     assertEq(stablecoin.balanceOf(user), borrowAmount);
    // }


    // // function test_borrow_with_large_rate_PENDLE() public {
    // //     // accure interest
    // //     vm.warp(block.timestamp + 10 * 365 days);

    // //     uint256 depositAmount = 10_000 ether;
    // //     uint256 borrowAmount = 5_000 ether;
    // //     _depositAndBorrow(userProxy, address(pendleVault_STETH), depositAmount, borrowAmount);

    // //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));

    // //     // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
    // //     assertEq(collateral, depositAmount);

    // //     // assert normalDebt is the same as the amount of stablecoin borrowed
    // //     assertEq(normalDebt, _debtToNormalDebt(address(pendleVault_STETH), borrowAmount));

    // //     // assert that debt is minted to the user
    // //     assertEq(stablecoin.balanceOf(user), borrowAmount);
    // // }


    // function test_borrow_as_permission_agent_PENDLE() public {
    //     // create 2nd position
    //     address alice = vm.addr(0x45674567);
    //     PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));

    //     // add collateral to 1st position
    //     uint256 upFrontUnderliers = 10_000 ether;
    //     _deposit(userProxy, address(pendleVault_STETH), upFrontUnderliers);

    //     uint256 borrowAmount = 5_000 ether;

    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: alice,
    //         auxSwap: emptySwap // no exit swap
    //     });

    //     // attempt to borrow from the 1st position as the 2nd position, expect revert due to lack of permission
    //     vm.prank(alice);
    //     vm.expectRevert(CDPVault.CDPVault__modifyCollateralAndDebt_noPermission.selector);
    //     aliceProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.borrow.selector,
    //             address(userProxy),
    //             address(pendleVault_STETH),
    //             creditParams
    //         )
    //     );

    //     // grant alice permission
    //     vm.startPrank(address(userProxy));
    //     cdm.setPermissionAgent(address(aliceProxy), true); // allow 2nd position to mint stablecoin using credit
    //     pendleVault_STETH.modifyPermission(address(aliceProxy), true); // allow alice to modify this vault
    //     vm.stopPrank();


    //     // expect borrow to succeed
    //     vm.prank(alice);
    //     aliceProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.borrow.selector,
    //             address(userProxy),
    //             address(pendleVault_STETH),
    //             creditParams
    //         )
    //     );



    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));

    //     assertEq(collateral, upFrontUnderliers);
    //     assertEq(normalDebt, borrowAmount);

    //     assertEq(stablecoin.balanceOf(alice), borrowAmount);


    // }

  

    // // REPAY TESTS


    // function test_repay_PENDLE() public {
    //     uint256 depositAmount = 1_000*1 ether; // LP_STETH
    //     uint256 borrowAmount = 500*1 ether; // stablecoin
    //     _depositAndBorrow(userProxy, address(pendleVault_STETH), depositAmount, borrowAmount);

    //     // build repay params
    //     SwapParams memory auxSwap;
    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: user,
    //         auxSwap: auxSwap // no entry swap
    //     });

    //     vm.startPrank(user);
    //     stablecoin.approve(address(userProxy), borrowAmount);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.repay.selector,
    //             address(userProxy), // user proxy is the position
    //             address(pendleVault_STETH),
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );
    //     vm.stopPrank();

    //     (uint256 collateral, uint256 debt) = pendleVault_STETH.positions(address(userProxy));
    //     uint256 creditAmount = credit(address(userProxy));

    //     assertEq(collateral, depositAmount);
    //     assertEq(debt, 0);
    //     assertEq(creditAmount, 0);
    //     assertEq(stablecoin.balanceOf(user), 0);
    // }

 

    // function test_repay_with_interest_PENDLE() public {
    //     uint256 depositAmount = 1_000*1 ether; // LP_STETH
    //     uint256 borrowAmount = 500*1 ether; // stablecoin
    //     _depositAndBorrow(userProxy, address(pendleVault_STETH), depositAmount, borrowAmount);

    //     // accrue interest
    //     vm.warp(block.timestamp + 365 days);

    //     uint256 totalDebt = _virtualDebt(pendleVault_STETH, address(userProxy));
    //     deal(address(stablecoin), user, totalDebt); // update stablecoin balance to cover normal debt plus accrued interest

    //     // build repay params
    //     SwapParams memory auxSwap;
    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: user,
    //         auxSwap: auxSwap // no entry swap
    //     });

    //     vm.startPrank(user);
    //     stablecoin.approve(address(userProxy), totalDebt);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.repay.selector,
    //             address(userProxy), // user proxy is the position
    //             address(pendleVault_STETH),
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );
    //     vm.stopPrank();

    //     (uint256 collateral, uint256 debt) = pendleVault_STETH.positions(address(userProxy));
    //     uint256 creditAmount = credit(address(userProxy));

    //     assertEq(collateral, depositAmount);
    //     assertEq(debt, 0);
    //     assertEq(creditAmount, 0);
    //     assertEq(stablecoin.balanceOf(user), 0);

    // }


    // function test_withdrawAndRepay_PENDLE() public {
    //     uint256 depositAmount = 5_000*1 ether;
    //     uint256 borrowAmount = 2_500*1 ether;

    //     // deposit and borrow
    //     _depositAndBorrow(userProxy, address(pendleVault_STETH), depositAmount, borrowAmount);

    //     // build withdraw and repay params
    //     CollateralParams memory collateralParams;
    //     CreditParams memory creditParams;
    //     {
    //         collateralParams = CollateralParams({
    //             targetToken: address(PENDLE_LP_STETH),
    //             amount: depositAmount,
    //             collateralizer: user,
    //             auxSwap: emptySwap
    //         });
    //         creditParams = CreditParams({
    //             amount: borrowAmount,
    //             creditor: user,
    //             auxSwap: emptySwap
    //         });
    //     }

    //     vm.startPrank(user);
    //     stablecoin.approve(address(userProxy), borrowAmount);

    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.withdrawAndRepay.selector,
    //             address(userProxy), // user proxy is the position
    //             address(pendleVault_STETH),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );
    //     vm.stopPrank();


    //     (uint256 collateral, uint256 debt) = pendleVault_STETH.positions(address(userProxy));
    //     uint256 creditAmount = credit(address(userProxy));

    //     assertEq(collateral, 0);
    //     assertEq(debt, 0);
    //     assertEq(creditAmount, 0);
    //     assertEq(stablecoin.balanceOf(user), 0);
    //     assertEq(PENDLE_LP_STETH.balanceOf(user), depositAmount);
    // }


    // function test_depositAndBorrow_PENDLE() public {
    //     uint256 upFrontUnderliers = 10_000*1 ether;
    //     uint256 borrowAmount = 5_000*1 ether;

    //     deal(address(PENDLE_LP_STETH), user, upFrontUnderliers);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(PENDLE_LP_STETH),
    //         amount: upFrontUnderliers,
    //         collateralizer: address(user),
    //         auxSwap: emptySwap // no entry swap
    //     });
    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: user,
    //         auxSwap: emptySwap // no exit swap
    //     });

    //     vm.prank(user);
    //     PENDLE_LP_STETH.approve(address(userProxy), upFrontUnderliers);

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.depositAndBorrow.selector,
    //             address(userProxy),
    //             address(pendleVault_STETH),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));

    //     assertEq(collateral, upFrontUnderliers);
    //     assertEq(normalDebt, borrowAmount);

    //     assertEq(stablecoin.balanceOf(user), borrowAmount);
    // }


    // // MULTISEND

    // function test_multisend_simple_delegatecall_PENDLE() public {
    //     uint256 depositAmount = 1_000 ether;
    //     uint256 borrowAmount = 500 ether;

    //     deal(address(PENDLE_LP_STETH), address(userProxy), depositAmount);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(PENDLE_LP_STETH),
    //         amount: depositAmount,
    //         collateralizer: address(userProxy),
    //         auxSwap: emptySwap
    //     });

    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: address(userProxy),
    //         auxSwap: emptySwap
    //     });

    //     address[] memory targets = new address[](2);
    //     targets[0] = address(positionAction);
    //     targets[1] = address(pendleVault_STETH);

    //     bytes[] memory data = new bytes[](2);
    //     data[0] = abi.encodeWithSelector(
    //         positionAction.depositAndBorrow.selector,
    //         address(userProxy),
    //         address(pendleVault_STETH),
    //         collateralParams,
    //         creditParams,
    //         emptyPermitParams
    //     );
    //     data[1] = abi.encodeWithSelector(CDPVault.modifyCollateralAndDebt.selector,
    //         address(userProxy),
    //         address(userProxy),
    //         address(userProxy),
    //         0,
    //         0
    //     );

    //     bool[] memory delegateCall = new bool[](2);
    //     delegateCall[0] = true;
    //     delegateCall[1] = false;

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.multisend.selector,
    //             targets,
    //             data,
    //             delegateCall
    //         )
    //     );

    //     (uint256 collateral, uint256 debt) = pendleVault_STETH.positions(address(userProxy));
    //     assertEq(collateral, depositAmount);
    //     assertEq(debt, borrowAmount);
    // }

    // function test_multisend_deposit_PENDLE() public {
    //     uint256 depositAmount = 10_000 ether;

    //     deal(address(PENDLE_LP_STETH), user, depositAmount);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(PENDLE_LP_STETH),
    //         amount: depositAmount,
    //         collateralizer: address(user),
    //         auxSwap: emptySwap
    //     });

    //     vm.prank(user);
    //     PENDLE_LP_STETH.approve(address(userProxy), depositAmount);

    //     address[] memory targets = new address[](2);
    //     targets[0] = address(positionAction);
    //     targets[1] = address(pendleVault_STETH);

    //     bytes[] memory data = new bytes[](2);
    //     data[0] = abi.encodeWithSelector(positionAction.deposit.selector, address(userProxy), pendleVault_STETH, collateralParams, emptyPermitParams);
    //     data[1] = abi.encodeWithSelector(
    //         pendleVault_STETH.modifyCollateralAndDebt.selector,
    //         address(userProxy),
    //         address(userProxy),
    //         address(userProxy),
    //         0,
    //         toInt256(100 ether)
    //     );

    //     bool[] memory delegateCall = new bool[](2);
    //     delegateCall[0] = true;
    //     delegateCall[1] = false;

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.multisend.selector,
    //             targets,
    //             data,
    //             delegateCall
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = pendleVault_STETH.positions(address(userProxy));

    //     assertEq(collateral, depositAmount);
    //     assertEq(normalDebt, 100 ether);
    // }

    // // HELPER FUNCTIONS

    // function _deposit(PRBProxy proxy, address vault, uint256 amount) internal {
    //     CDPVault cdpVault = CDPVault(vault);
    //     address token = address(cdpVault.token());

    //     // mint vault token to position
    //     deal(token, address(proxy), amount);

    //     // build collateral params
    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: token,
    //         amount: amount,
    //         collateralizer: address(proxy),
    //         auxSwap: emptySwap
    //     });

    //     vm.prank(proxy.owner());
    //     proxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.deposit.selector,
    //             address(userProxy), // user proxy is the position
    //             vault,
    //             collateralParams,
    //             emptyPermitParams
    //         )
    //     );
    // }

    // function _borrow(PRBProxy proxy, address vault, uint256 borrowAmount) internal {
    //     // build borrow params
    //     SwapParams memory auxSwap;
    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: address(proxy),
    //         auxSwap: auxSwap // no entry swap
    //     });

    //     vm.prank(proxy.owner());
    //     proxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.borrow.selector,
    //             address(proxy), // user proxy is the position
    //             vault,
    //             creditParams
    //         )
    //     );
    // }

    // function _depositAndBorrow(PRBProxy proxy, address vault, uint256 depositAmount, uint256 borrowAmount) internal {
    //     CDPVault cdpVault = CDPVault(vault);
    //     address token = address(cdpVault.token());

    //     // mint vault token to position
    //     deal(token, address(proxy), depositAmount);

    //     // build add collateral params
    //     SwapParams memory auxSwap;
    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: token,
    //         amount: depositAmount,
    //         collateralizer: address(proxy),
    //         auxSwap: auxSwap // no entry swap
    //     });
    //     CreditParams memory creditParams = CreditParams({
    //         amount: borrowAmount,
    //         creditor: proxy.owner(),
    //         auxSwap: auxSwap // no exit swap
    //     });

    //     vm.startPrank(proxy.owner());
    //     proxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.depositAndBorrow.selector,
    //             address(proxy), // user proxy is the position
    //             vault,
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );
    //     vm.stopPrank();
    // }

    function getForkBlockNumber() override internal pure returns (uint256) {
        return 19356381;
    }
}
