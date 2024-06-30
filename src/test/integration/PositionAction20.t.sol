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

contract PositionAction20Test is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault vault;

    // actions
    PositionAction20 positionAction;

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    function setUp() public override {
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        vault = createCDPVault(
            token, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        vm.prank(address(userProxy));
        token.approve(address(user), type(uint256).max);
        vm.prank(address(userProxy));
        mockWETH.approve(address(user), type(uint256).max);

        // deploy position actions
        positionAction = new PositionAction20(address(flashlender), address(swapAction), address(poolAction));

        vm.label(user, "user");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(vault), "cdpVault");
        vm.label(address(positionAction), "positionAction");
    }

    function test_deposit() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(token), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(token),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        token.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt, , ) = vault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_vault_with_entry_swap_from_USDC() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint256 amountOutMin = depositAmount * 1e12 * 98 / 100; // convert 6 decimals to 18 and add 1% slippage

        deal(address(USDC), user, depositAmount);

        // build increase collateral params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(token);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDC),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(USDC),
                amount: depositAmount, // amount to swap in
                limit: amountOutMin, // min amount of collateral token to receive
                recipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedCollateral = _simulateBalancerSwap(collateralParams.auxSwap);

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);


        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt, ,) = vault.positions(address(userProxy));

        assertEq(collateral, expectedCollateral);
        assertEq(normalDebt, 0);
    }

    function test_deposit_from_proxy_collateralizer() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(token), address(userProxy), depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(token),
            amount: depositAmount,
            collateralizer: address(userProxy),
            auxSwap: emptySwap
        });


        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt, ,) = vault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_to_an_unrelated_position() public {

        // create 2nd position
        address alice = vm.addr(0x45674567);
        PRBProxy aliceProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(alice))));

        uint256 depositAmount = 10_000 ether;

        deal(address(token), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(token),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap // no entry swap
        });

        vm.prank(user);
        token.approve(address(userProxy), depositAmount);

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(aliceProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 normalDebt, , ) = vault.positions(address(aliceProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
    }

    function test_deposit_EXACT_OUT() public {
        uint256 depositAmount = 10_000 ether;
        //uint256 amountOutMin = depositAmount * 1e12 * 98 / 100; 
        uint256 amountInMax = depositAmount * 101 / 100e12; // convert 6 decimals to 18 and add 1% slippage

        deal(address(USDC), user, amountInMax);

        // build increase collateral params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(token);
        assets[1] = address(USDC);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDC),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(USDC),
                amount: depositAmount, // amount to swap in
                limit: amountInMax, // min amount of collateral token to receive
                recipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        uint256 expectedAmountIn = _simulateBalancerSwap(collateralParams.auxSwap);

        vm.startPrank(user);
        USDC.approve(address(userProxy), amountInMax);


        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt, ,) = vault.positions(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
        assertEq(USDC.balanceOf(user), amountInMax - expectedAmountIn); // assert residual is sent to user
    }

    function test_deposit_InvalidAuxSwap() public {
        uint256 depositAmount = 10_000 * 1e6;
        uint256 amountOutMin = depositAmount * 1e12 * 98 / 100; // convert 6 decimals to 18 and add 1% slippage

        deal(address(USDC), user, depositAmount);

        // build increase collateral params
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = stablePoolId;

        address[] memory assets = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(token);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(USDC),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(USDC),
                amount: depositAmount, // amount to swap in
                limit: amountOutMin, // min amount of collateral token to receive
                recipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(poolIds, assets)
            })
        });

        vm.prank(user);
        USDC.approve(address(userProxy), depositAmount);

        // trigger PositionAction__deposit_InvalidAuxSwap
        collateralParams.auxSwap.recipient = user;
        vm.expectRevert(PositionAction.PositionAction__deposit_InvalidAuxSwap.selector);
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
    }

    function test_withdraw() public {
        // deposit tokens to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(vault), initialDeposit);

        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(token),
            amount: initialDeposit,
            collateralizer: address(user),
            auxSwap: auxSwap
        });

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(vault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt, ,) = vault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        // (int256 balance,) = cdm.accounts(address(userProxy));
        // assertEq(balance, 0);
    }

    function test_withdraw_and_swap() public {
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(vault), initialDeposit);

        // build withdraw params
        uint256 expectedAmountOut;
        CollateralParams memory collateralParams;
        {
            bytes32[] memory poolIds = new bytes32[](1);
            poolIds[0] = stablePoolId;

            address[] memory assets = new address[](2);
            assets[0] = address(token);
            assets[1] = address(USDT);

            collateralParams = CollateralParams({
                targetToken: address(token),
                amount: initialDeposit,
                collateralizer: address(user),
                auxSwap: SwapParams({
                    swapProtocol: SwapProtocol.BALANCER,
                    swapType: SwapType.EXACT_IN,
                    assetIn: address(token),
                    amount: initialDeposit,
                    limit: initialDeposit/1e12 * 99/100,
                    recipient: address(user),
                    deadline: block.timestamp + 100,
                    args: abi.encode(poolIds, assets)
                })
            });
            expectedAmountOut = _simulateBalancerSwap(collateralParams.auxSwap);
        }

        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // user proxy is the position
                address(vault),
                collateralParams
            )
        );

        (uint256 collateral, uint256 normalDebt, ,) = vault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
        
        // (int256 balance,) = cdm.accounts(address(userProxy));
        // assertEq(balance, 0);
        assertEq(USDT.balanceOf(address(user)), expectedAmountOut);
    }

    function test_borrow_123() public {
        // deposit to vault
        uint256 initialDeposit = 1_000 ether;
        _deposit(userProxy, address(vault), initialDeposit);

        // borrow against deposit
        uint256 borrowAmount = 500*1 ether;
        deal(address(token), user, borrowAmount);

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
                address(vault),
                creditParams
            )
        );

        (uint256 collateral, uint256 normalDebt, ,) = vault.positions(address(userProxy));
        assertEq(collateral, initialDeposit);
        assertEq(normalDebt, borrowAmount);

        // (int256 balance,) = cdm.accounts(address(userProxy));
        // assertEq(balance, 0);
        assertEq(token.balanceOf(user), borrowAmount);
    }

    function test_borrow_with_large_rate() public {
        // accrue interest
        vm.warp(block.timestamp + 10 * 365 days);

        uint256 depositAmount = 10_000 ether;
        uint256 borrowAmount = 5_000 ether;
        _depositAndBorrow(userProxy, address(vault), depositAmount, borrowAmount);

        (uint256 collateral, uint256 normalDebt, ,) = vault.positions(address(userProxy));

        // assert that collateral is now equal to the upFrontAmount + the amount of DAI received from the swap
        assertEq(collateral, depositAmount);

        // assert normalDebt is the same as the amount of stablecoin borrowed
        assertLt(normalDebt, _virtualDebt(vault, address(userProxy)));

        // assert that debt is minted to the user
        assertEq(underlyingToken.balanceOf(user), borrowAmount);
    }

    // REPAY TESTS

    function test_repay() public {
        uint256 depositAmount = 1_000*1 ether;
        uint256 borrowAmount = 500*1 ether;
        _depositAndBorrow(userProxy, address(vault), depositAmount, borrowAmount);

        // build repay params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: user,
            auxSwap: auxSwap // no entry swap
        });

        vm.startPrank(user);
        underlyingToken.approve(address(userProxy), borrowAmount);
        underlyingToken.approve(address(liquidityPool), borrowAmount);
        
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.repay.selector,
                address(userProxy), // user proxy is the position
                address(vault),
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 debt, ,) = vault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(underlyingToken.balanceOf(user), 0);
    }

    function test_repay_with_interest() public {
        uint256 depositAmount = 1_000*1 ether;
        uint256 borrowAmount = 500*1 ether;
        _depositAndBorrow(userProxy, address(vault), depositAmount, borrowAmount);

        // accrue interest
        vm.warp(block.timestamp + 365 days);

        uint256 totalDebt = _virtualDebt(vault, address(userProxy));
        deal(address(underlyingToken), user, totalDebt);

        // build repay params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: totalDebt,
            creditor: user,
            auxSwap: auxSwap // no entry swap
        });

        vm.startPrank(user);
        underlyingToken.approve(address(userProxy), totalDebt);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.repay.selector,
                address(userProxy), // user proxy is the position
                address(vault),
                creditParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();

        (uint256 collateral, uint256 debt, ,) = vault.positions(address(userProxy));
        uint256 creditAmount = credit(address(userProxy));

        assertEq(collateral, depositAmount);
        assertEq(debt, 0);
        assertEq(creditAmount, 0);
        assertEq(underlyingToken.balanceOf(user), 0);
    }

    // function test_repay_with_interest_with_swap() public {
    //     uint256 collateral = 1_000*1 ether; // DAI
    //     uint256 normalDebt = 500*1 ether; // stablecoin
    //     _depositAndBorrow(userProxy, address(daiVault), collateral, normalDebt);

    //     // get rid of the stablecoin that was borrowed
    //     vm.prank(user);
    //     stablecoin.transfer(address(0x1), normalDebt);

    //     // accrue interest
    //     vm.warp(block.timestamp + 365 days);
    //     uint256 debt = _virtualDebt(daiVault, address(userProxy));

    //     // mint usdc to pay back with
    //     uint256 swapAmount = debt/1e12 * 101/100;
    //     deal(address(USDC), address(user), swapAmount);

    //    // build repay params
    //    uint256 expectedAmountIn;
    //    CreditParams memory creditParams;
    //    {
    //         bytes32[] memory poolIds = new bytes32[](1);
    //         poolIds[0] = stablePoolId;

    //         address[] memory assets = new address[](2);
    //         assets[0] = address(stablecoin);
    //         assets[1] = address(USDC);

    //         creditParams = CreditParams({
    //             amount: normalDebt,
    //             creditor: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(USDC),
    //                 amount: debt,
    //                 limit: swapAmount,
    //                 recipient: address(userProxy),
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(poolIds, assets)
    //             })
    //         });
    //         expectedAmountIn = _simulateBalancerSwap(creditParams.auxSwap);
    //    }

    //    vm.startPrank(user);
    //    USDC.approve(address(userProxy), swapAmount);
    //    userProxy.execute(
    //        address(positionAction),
    //        abi.encodeWithSelector(
    //            positionAction.repay.selector,
    //            address(userProxy), // user proxy is the position
    //            address(daiVault),
    //            creditParams,
    //            emptyPermitParams
    //        )
    //    );
    //    vm.stopPrank();

    //    (uint256 vCollateral, uint256 vNormalDebt) = daiVault.positions(address(userProxy));
    //    uint256 creditAmount = credit(address(userProxy));

    //    assertEq(vCollateral, collateral);
    //    assertEq(vNormalDebt, 0);
    //    assertEq(creditAmount, 0);
    //    assertEq(stablecoin.balanceOf(user), 0);
    // }

    // function test_repay_from_swap() public {
    //     uint256 depositAmount = 1_000*1 ether; // DAI
    //     uint256 borrowAmount = 500*1 ether; // stablecoin
    //     _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

    //     // mint usdc to pay back with
    //     uint256 swapAmount = borrowAmount/1e12 * 101/100;
    //     deal(address(USDC), address(user), swapAmount);

    //     // get rid of the stablecoin that was borrowed
    //     vm.prank(user);
    //     stablecoin.transfer(address(0x1), borrowAmount);

    //    // build repay params
    //    uint256 expectedAmountIn;
    //    CreditParams memory creditParams;
    //    {
    //         bytes32[] memory poolIds = new bytes32[](1);
    //         poolIds[0] = stablePoolId;

    //         address[] memory assets = new address[](2);
    //         assets[0] = address(stablecoin);
    //         assets[1] = address(USDC);

    //         creditParams = CreditParams({
    //             amount: borrowAmount,
    //             creditor: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(USDC),
    //                 amount: borrowAmount,
    //                 limit: swapAmount,
    //                 recipient: address(userProxy),
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(poolIds, assets)
    //             })
    //         });
    //         expectedAmountIn = _simulateBalancerSwap(creditParams.auxSwap);
    //    }

    //    vm.startPrank(user);
    //    USDC.approve(address(userProxy), swapAmount);
    //    userProxy.execute(
    //        address(positionAction),
    //        abi.encodeWithSelector(
    //            positionAction.repay.selector,
    //            address(userProxy), // user proxy is the position
    //            address(daiVault),
    //            creditParams,
    //            emptyPermitParams
    //        )
    //    );
    //    vm.stopPrank();

    //    (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
    //    uint256 creditAmount = credit(address(userProxy));

    //    assertEq(collateral, depositAmount);
    //    assertEq(normalDebt, 0);
    //    assertEq(creditAmount, 0);
    //    assertEq(stablecoin.balanceOf(user), 0);
    // }

    // function test_repay_from_swap_EXACT_IN() public {
    //     uint256 depositAmount = 1_000*1 ether; // DAI
    //     uint256 borrowAmount = 500*1 ether; // stablecoin
    //     _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

    //     // mint usdc to pay back with
    //     uint256 swapAmount = ((borrowAmount/2) * 101)/100e12; // repay half debt, mint extra to ensure our minimum is the exact amount
    //     deal(address(USDC), address(user), swapAmount);

    //     // get rid of the stablecoin that was borrowed
    //     vm.prank(user);
    //     stablecoin.transfer(address(0x1), borrowAmount);

    //    // build repay params
    //    uint256 expectedAmountOut;
    //    CreditParams memory creditParams;
    //    {
    //         bytes32[] memory poolIds = new bytes32[](1);
    //         poolIds[0] = stablePoolId;

    //         address[] memory assets = new address[](2);
    //         assets[0] = address(USDC);
    //         assets[1] = address(stablecoin);

    //         creditParams = CreditParams({
    //             amount: borrowAmount/2,
    //             creditor: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_IN,
    //                 assetIn: address(USDC),
    //                 amount: swapAmount,
    //                 limit: borrowAmount/2,
    //                 recipient: address(userProxy),
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(poolIds, assets)
    //             })
    //         });
    //         expectedAmountOut = _simulateBalancerSwap(creditParams.auxSwap);
    //    }

    //    vm.startPrank(user);
    //    USDC.approve(address(userProxy), swapAmount);
    //    userProxy.execute(
    //        address(positionAction),
    //        abi.encodeWithSelector(
    //            positionAction.repay.selector,
    //            address(userProxy), // user proxy is the position
    //            address(daiVault),
    //            creditParams,
    //            emptyPermitParams
    //        )
    //    );
    //    vm.stopPrank();

    //    (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));
    //    uint256 creditAmount = credit(address(userProxy));

    //    assertEq(collateral, depositAmount);
    //    assertEq(normalDebt, borrowAmount/2);
    //    assertEq(creditAmount, expectedAmountOut - borrowAmount/2); // ensure that any extra credit is stored as credit for the user
    //    assertEq(stablecoin.balanceOf(user), 0);
    // }

    // function test_repay_InvalidAuxSwap() public {
    //     uint256 depositAmount = 1_000*1 ether; // DAI
    //     uint256 borrowAmount = 500*1 ether; // stablecoin
    //     _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

    //     // mint usdc to pay back with
    //     uint256 swapAmount = borrowAmount/1e12 * 101/100;
    //     deal(address(USDC), address(user), swapAmount);

    //     // get rid of the stablecoin that was borrowed
    //     vm.prank(user);
    //     stablecoin.transfer(address(0x1), borrowAmount);

    //    // build repay params
    //    uint256 expectedAmountIn;
    //    CreditParams memory creditParams;
    //    {
    //         bytes32[] memory poolIds = new bytes32[](1);
    //         poolIds[0] = stablePoolId;

    //         address[] memory assets = new address[](2);
    //         assets[0] = address(stablecoin);
    //         assets[1] = address(USDC);

    //         creditParams = CreditParams({
    //             amount: borrowAmount,
    //             creditor: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(USDC),
    //                 amount: borrowAmount,
    //                 limit: swapAmount,
    //                 recipient: address(userProxy),
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(poolIds, assets)
    //             })
    //         });
    //         expectedAmountIn = _simulateBalancerSwap(creditParams.auxSwap);
    //    }

    //    vm.prank(user);
    //    USDC.approve(address(userProxy), swapAmount);

    //    // trigger PositionAction__repay_InvalidAuxSwap
    //    creditParams.auxSwap.recipient = user;
    //    vm.prank(user);
    //    vm.expectRevert(PositionAction.PositionAction__repay_InvalidAuxSwap.selector);
    //    userProxy.execute(
    //        address(positionAction),
    //        abi.encodeWithSelector(
    //            positionAction.repay.selector,
    //            address(userProxy), // user proxy is the position
    //            address(daiVault),
    //            creditParams,
    //            emptyPermitParams
    //        )
    //    );
    // }

    // function test_withdrawAndRepay() public {
    //     uint256 depositAmount = 5_000*1 ether;
    //     uint256 borrowAmount = 2_500*1 ether;

    //     // deposit and borrow
    //     _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

    //     // build withdraw and repay params
    //     CollateralParams memory collateralParams;
    //     CreditParams memory creditParams;
    //     {
    //         collateralParams = CollateralParams({
    //             targetToken: address(DAI),
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
    //             address(daiVault),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );
    //     vm.stopPrank();


    //     (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
    //     uint256 creditAmount = credit(address(userProxy));

    //     assertEq(collateral, 0);
    //     assertEq(debt, 0);
    //     assertEq(creditAmount, 0);
    //     assertEq(stablecoin.balanceOf(user), 0);
    //     assertEq(DAI.balanceOf(user), depositAmount);
    // }

    // function test_withdrawAndRepay_with_swaps() public {
    //     uint256 depositAmount = 5_000*1 ether;
    //     uint256 borrowAmount = 2_500*1 ether;

    //     // deposit and borrow
    //     _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

    //     // spend users stablecoin
    //     vm.prank(user);
    //     stablecoin.transfer(address(0x1), borrowAmount);

    //     // build withdraw and repay params
    //     CollateralParams memory collateralParams;
    //     CreditParams memory creditParams;
    //     uint256 debtSwapMaxAmountIn = borrowAmount * 101 /100e12;
    //     uint256 debtSwapAmountIn;
    //     uint256 expectedCollateralOut;
    //     {
    //         address[] memory collateralAssets = new address[](2);
    //         collateralAssets[0] = address(DAI);
    //         collateralAssets[1] = address(USDC);

    //         address[] memory debtAssets = new address[](2);
    //         debtAssets[0] = address(stablecoin);
    //         debtAssets[1] = address(USDC);

    //         collateralParams = CollateralParams({
    //             targetToken: address(USDC),
    //             amount: depositAmount,
    //             collateralizer: user,
    //             auxSwap: SwapParams({ // swap DAI for USDC
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_IN,
    //                 assetIn: address(DAI),
    //                 amount: depositAmount,
    //                 limit: depositAmount * 99/100e12,
    //                 recipient: address(user), // sent directly to the user
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(stablePoolIdArray, collateralAssets)
    //             })
    //         });
    //         creditParams = CreditParams({
    //             amount: borrowAmount,
    //             creditor: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(USDC),
    //                 amount: borrowAmount,
    //                 limit: debtSwapMaxAmountIn,
    //                 recipient: address(userProxy), // must be sent to proxy
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(stablePoolIdArray, debtAssets)
    //             })
    //         });
    //         (debtSwapAmountIn, expectedCollateralOut) = _simulateBalancerSwapMulti(creditParams.auxSwap, collateralParams.auxSwap);
    //     }

    //     vm.startPrank(user);
    //     deal(address(USDC), address(user), debtSwapMaxAmountIn);
    //     USDC.approve(address(userProxy), debtSwapMaxAmountIn);

    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.withdrawAndRepay.selector,
    //             address(userProxy), // user proxy is the position
    //             address(daiVault),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );
    //     vm.stopPrank();


    //     // ensure that users position is cleared out
    //     (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
    //     uint256 creditAmount = credit(address(userProxy));
    //     assertEq(collateral, 0);
    //     assertEq(debt, 0);
    //     assertEq(creditAmount, 0);

    //     // ensure that ERC20 balances are as expected
    //     assertEq(stablecoin.balanceOf(address(userProxy)), 0); // ensure no stablecoin has been left on proxy
    //     assertEq(stablecoin.balanceOf(user), 0); // ensure no stablecoin has been left on user eoa

    //     // ensure that left over USDC from debt swap is kept on proxy and USDC from collateral swap is sent to user
    //     assertEq(USDC.balanceOf(user), expectedCollateralOut + debtSwapMaxAmountIn - debtSwapAmountIn);
    // }

    // // withdraw dai and swap to usdc, then repay usdc debt by swapping to stablecoin
    // function test_withdrawAndRepay_with_EXACT_OUT_swaps() public {
    //     uint256 depositAmount = 5_000*1 ether;
    //     uint256 borrowAmount = 2_500*1 ether;

    //     // deposit and borrow
    //     _depositAndBorrow(userProxy, address(daiVault), depositAmount, borrowAmount);

    //     // spend users stablecoin
    //     vm.prank(user);
    //     stablecoin.transfer(address(0x1), borrowAmount);

    //     // build withdraw and repay params
    //     CollateralParams memory collateralParams;
    //     CreditParams memory creditParams;
    //     uint256 debtSwapMaxAmountIn = borrowAmount * 101 /100e12;
    //     uint256 collateralSwapOut = depositAmount * 99/100e12;
    //     uint256 debtSwapAmountIn; // usdc spent swapping debt to stablecoin
    //     uint256 expectedCollateralIn; // dai spent swapping collateral to usdc
    //     {
    //         address[] memory collateralAssets = new address[](2);
    //         collateralAssets[0] = address(USDC);
    //         collateralAssets[1] = address(DAI);

    //         address[] memory debtAssets = new address[](2);
    //         debtAssets[0] = address(stablecoin);
    //         debtAssets[1] = address(USDC);

    //         collateralParams = CollateralParams({
    //             targetToken: address(USDC),
    //             amount: depositAmount,
    //             collateralizer: user,
    //             auxSwap: SwapParams({ // swap DAI for USDC
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(DAI),
    //                 amount: collateralSwapOut,
    //                 limit: depositAmount,
    //                 recipient: address(user), // sent directly to the user
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(stablePoolIdArray, collateralAssets)
    //             })
    //         });
    //         creditParams = CreditParams({
    //             amount: borrowAmount,
    //             creditor: user,
    //             auxSwap: SwapParams({ // swap USDC for stablecoin
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(USDC),
    //                 amount: borrowAmount,
    //                 limit: debtSwapMaxAmountIn,
    //                 recipient: address(userProxy), // must be sent to proxy
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(stablePoolIdArray, debtAssets)
    //             })
    //         });
    //         (debtSwapAmountIn, expectedCollateralIn) = _simulateBalancerSwapMulti(creditParams.auxSwap, collateralParams.auxSwap);
    //     }

    //     vm.startPrank(user);
    //     deal(address(USDC), address(user), debtSwapMaxAmountIn);
    //     USDC.approve(address(userProxy), debtSwapMaxAmountIn);

    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.withdrawAndRepay.selector,
    //             address(userProxy), // user proxy is the position
    //             address(daiVault),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );
    //     vm.stopPrank();


    //     // ensure that users position is cleared out
    //     (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
    //     uint256 creditAmount = credit(address(userProxy));
    //     assertEq(collateral, 0);
    //     assertEq(debt, 0);
    //     assertEq(creditAmount, 0);

    //     // ensure that ERC20 balances are as expected
    //     assertEq(stablecoin.balanceOf(address(userProxy)), 0); // ensure no stablecoin has been left on proxy
    //     assertEq(stablecoin.balanceOf(user), 0); // ensure no stablecoin has been left on user eoa

    //     // ensure that left over USDC from debt swap and amount of from collateral swap is sent to user
    //     assertEq(USDC.balanceOf(user), collateralSwapOut + debtSwapMaxAmountIn - debtSwapAmountIn);
    //     assertEq(DAI.balanceOf(user), depositAmount - expectedCollateralIn); // ensure user got left over dai from collateral exact_out swap
    // }

    // function test_depositAndBorrow() public {
    //     uint256 upFrontUnderliers = 10_000*1 ether;
    //     uint256 borrowAmount = 5_000*1 ether;

    //     deal(address(DAI), user, upFrontUnderliers);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(DAI),
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
    //     DAI.approve(address(userProxy), upFrontUnderliers);

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.depositAndBorrow.selector,
    //             address(userProxy),
    //             address(daiVault),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

    //     assertEq(collateral, upFrontUnderliers);
    //     assertEq(normalDebt, borrowAmount);

    //     assertEq(stablecoin.balanceOf(user), borrowAmount);
    // }

    // // enter a DAI vault with USDC and exit with USDT
    // function test_depositAndBorrow_with_entry_and_exit_swaps() public {
    //     uint256 upFrontUnderliers = 10_000*1e6; // in USDC
    //     uint256 borrowAmount = 5_000*1 ether; // in stablecoin

    //     deal(address(USDC), user, upFrontUnderliers);

    //     CollateralParams memory collateralParams;
    //     CreditParams memory creditParams;
    //     uint256 expectedCollateral;
    //     uint256 expectedExitAmount;
    //     {

    //         address[] memory entryAssets = new address[](2);
    //         entryAssets[0] = address(USDC);
    //         entryAssets[1] = address(DAI);

    //         address[] memory exitAssets = new address[](2);
    //         exitAssets[0] = address(stablecoin);
    //         exitAssets[1] = address(USDT);

    //         collateralParams = CollateralParams({
    //             targetToken: address(USDC),
    //             amount: 0,
    //             collateralizer: address(user),
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_IN,
    //                 assetIn: address(USDC),
    //                 amount: upFrontUnderliers,
    //                 limit: upFrontUnderliers * 1e12 * 98 / 100, // amountOutMin in DAI 
    //                 recipient: address(userProxy),
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(stablePoolIdArray, entryAssets)
    //             })            
    //         });
    //         creditParams = CreditParams({
    //             amount: borrowAmount,
    //             creditor: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_IN,
    //                 assetIn: address(stablecoin),
    //                 amount: borrowAmount,
    //                 limit: borrowAmount * 98 / 100e12, // amountOutMin in USDT
    //                 recipient: user,
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(stablePoolIdArray, exitAssets)
    //             })
    //         });

    //         (expectedCollateral, expectedExitAmount) = _simulateBalancerSwapMulti(collateralParams.auxSwap, creditParams.auxSwap);
    //     }

    //     vm.prank(user);
    //     USDC.approve(address(userProxy), upFrontUnderliers);

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.depositAndBorrow.selector,
    //             address(userProxy),
    //             address(daiVault),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

    //     assertEq(collateral, expectedCollateral);
    //     assertEq(normalDebt, borrowAmount);

    //     assertEq(USDT.balanceOf(user), expectedExitAmount);
    // }

    // // enter a DAI vault with USDC and exit with USDT using EXACT_OUT swaps
    // function test_depositAndBorrow_with_EXACT_OUT_entry_and_exit_swaps() public {
    //     uint256 depositAmount = 10_100*1e6; // in USDC
    //     uint256 borrowAmount = 5_100*1 ether; // in stablecoin

    //     deal(address(USDC), user, depositAmount);

    //     CollateralParams memory collateralParams;
    //     CreditParams memory creditParams;
    //     uint256 expectedEntryIn;
    //     uint256 expectedExitIn;
    //     uint256 expectedCollateral = depositAmount * 99e12 / 100;
    //     uint256 expectedExit = borrowAmount * 99/100e12;
    //     {
    //         bytes32[] memory entryPoolIds = new bytes32[](1);
    //         entryPoolIds[0] = stablePoolId;

    //         address[] memory entryAssets = new address[](2);
    //         entryAssets[0] = address(DAI);
    //         entryAssets[1] = address(USDC);

    //         bytes32[] memory exitPoolIds = new bytes32[](1);
    //         exitPoolIds[0] = stablePoolId;

    //         address[] memory exitAssets = new address[](2);
    //         exitAssets[0] = address(USDT);
    //         exitAssets[1] = address(stablecoin);

    //         collateralParams = CollateralParams({
    //             targetToken: address(USDC),
    //             amount: 0,
    //             collateralizer: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(USDC),
    //                 amount: expectedCollateral,
    //                 limit: depositAmount, // amountInMax in USDC
    //                 recipient: address(userProxy),
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(entryPoolIds, entryAssets)
    //             })
    //         });
    //         creditParams = CreditParams({
    //             amount: borrowAmount,
    //             creditor: user,
    //             auxSwap: SwapParams({
    //                 swapProtocol: SwapProtocol.BALANCER,
    //                 swapType: SwapType.EXACT_OUT,
    //                 assetIn: address(stablecoin),
    //                 amount: expectedExit,
    //                 limit: borrowAmount, // amountInMax in stablecoin
    //                 recipient: address(user),
    //                 deadline: block.timestamp + 100,
    //                 args: abi.encode(exitPoolIds, exitAssets)
    //             })
    //         });

    //         (expectedEntryIn, expectedExitIn) = _simulateBalancerSwapMulti(collateralParams.auxSwap, creditParams.auxSwap);
    //     }

    //     vm.prank(user);
    //     USDC.approve(address(userProxy), depositAmount);

    //     vm.prank(user);
    //     userProxy.execute(
    //         address(positionAction),
    //         abi.encodeWithSelector(
    //             positionAction.depositAndBorrow.selector,
    //             address(userProxy),
    //             address(daiVault),
    //             collateralParams,
    //             creditParams,
    //             emptyPermitParams
    //         )
    //     );

    //     (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

    //     assertEq(collateral, expectedCollateral);
    //     assertEq(normalDebt, borrowAmount);

    //     // validate that the swap amounts are as expected w/ residual amounts being sent to msg.sender
    //     assertEq(USDT.balanceOf(user), expectedExit);
    //     assertEq(stablecoin.balanceOf(user), borrowAmount - expectedExitIn);

    //     // validate resiudal amounts from entry swap
    //     assertEq(USDC.balanceOf(address(user)), depositAmount - expectedEntryIn);

    //     // validate that there is no dust
    //     assertEq(USDT.balanceOf(address(userProxy)), 0);
    //     assertEq(stablecoin.balanceOf(address(userProxy)), 0);
    //     assertEq(DAI.balanceOf(address(userProxy)), 0);
    // }

    // // MULTISEND

    // // send a direct call to multisend and expect revert
    // function test_multisend_no_direct_call() public {
    //     address[] memory targets = new address[](1);
    //     targets[0] = address(DAI);

    //     bytes[] memory data = new bytes[](1);
    //     data[0] = abi.encodeWithSelector(DAI.balanceOf.selector, user);

    //     bool[] memory delegateCall = new bool[](1);
    //     delegateCall[0] = false;

    //     vm.expectRevert(PositionAction.PositionAction__onlyDelegatecall.selector);
    //     positionAction.multisend(targets, data, delegateCall);
    // }

    // function test_multisend_revert_on_inner_revert() public {
    //     address[] memory targets = new address[](1);
    //     targets[0] = address(DAI);

    //     bytes[] memory data = new bytes[](1);
    //     data[0] = abi.encodeWithSelector(PositionAction.multisend.selector); // random selector

    //     bool[] memory delegateCall = new bool[](1);
    //     delegateCall[0] = false;

    //     vm.expectRevert(BaseAction.Action__revertBytes_emptyRevertBytes.selector);
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
    // }

    // function test_multisend_simple_delegatecall() public {
    //     uint256 depositAmount = 1_000 ether;
    //     uint256 borrowAmount = 500 ether;

    //     deal(address(DAI), address(userProxy), depositAmount);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(DAI),
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
    //     targets[1] = address(daiVault);

    //     bytes[] memory data = new bytes[](2);
    //     data[0] = abi.encodeWithSelector(
    //         positionAction.depositAndBorrow.selector,
    //         address(userProxy),
    //         address(daiVault),
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

    //     (uint256 collateral, uint256 debt) = daiVault.positions(address(userProxy));
    //     assertEq(collateral, depositAmount);
    //     assertEq(debt, borrowAmount);
    // }

    // function test_multisend_deposit() public {
    //     uint256 depositAmount = 10_000 ether;

    //     deal(address(DAI), user, depositAmount);

    //     CollateralParams memory collateralParams = CollateralParams({
    //         targetToken: address(DAI),
    //         amount: depositAmount,
    //         collateralizer: address(user),
    //         auxSwap: emptySwap
    //     });

    //     vm.prank(user);
    //     DAI.approve(address(userProxy), depositAmount);

    //     address[] memory targets = new address[](2);
    //     targets[0] = address(positionAction);
    //     targets[1] = address(daiVault);

    //     bytes[] memory data = new bytes[](2);
    //     data[0] = abi.encodeWithSelector(positionAction.deposit.selector, address(userProxy), daiVault, collateralParams, emptyPermitParams);
    //     data[1] = abi.encodeWithSelector(
    //         daiVault.modifyCollateralAndDebt.selector,
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

    //     (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(userProxy));

    //     assertEq(collateral, depositAmount);
    //     assertEq(normalDebt, 100 ether);
    // }

    // HELPER FUNCTIONS

    function _deposit(PRBProxy proxy, address vault_, uint256 amount) internal {
        CDPVault cdpVault = CDPVault(vault_);
        address token = address(cdpVault.token());

        // mint vault token to position
        deal(token, address(proxy), amount);

        // build collateral params
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: token,
            amount: amount,
            collateralizer: address(proxy),
            auxSwap: emptySwap
        });

        vm.prank(proxy.owner());
        proxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy), // user proxy is the position
                vault,
                collateralParams,
                emptyPermitParams
            )
        );
    }

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

    function _depositAndBorrow(PRBProxy proxy, address vault_, uint256 depositAmount, uint256 borrowAmount) internal {
        CDPVault cdpVault = CDPVault(vault_);
        address token = address(cdpVault.token());

        // mint vault token to position
        deal(token, address(proxy), depositAmount);

        // build add collateral params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: token,
            amount: depositAmount,
            collateralizer: address(proxy),
            auxSwap: auxSwap // no entry swap
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
}
