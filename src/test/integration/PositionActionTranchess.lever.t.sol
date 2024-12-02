// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";
import {PRBProxyRegistry} from "../../prb-proxy/PRBProxyRegistry.sol";
import {WAD} from "../../utils/Math.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {PermitParams} from "../../proxy/TransferAction.sol";
import {PoolAction, PoolActionParams, Protocol} from "../../proxy/PoolAction.sol";

import {ApprovalType, PermitParams} from "../../proxy/TransferAction.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {PermitMaker} from "../utils/PermitMaker.sol";
import {PositionAction4626} from "../../proxy/PositionAction4626.sol";

import {IVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";

import {TokenInput, LimitOrderData} from "pendle/interfaces/IPAllActionTypeV3.sol";
import {ApproxParams} from "pendle/router/base/MarketApproxLib.sol";

import {TestBase} from "src/test/TestBase.sol";
import {Test} from "forge-std/Test.sol";
import {ActionMarketCoreStatic} from "pendle/offchain-helpers/router-static/base/ActionMarketCoreStatic.sol";
import {IUniswapV3Router, decodeLastToken, UniswapV3Router_decodeLastToken_invalidPath} from "../../vendor/IUniswapV3Router.sol";
import {IVault as IBalancerVault} from "../../vendor/IBalancerVault.sol";
import {IPActionAddRemoveLiqV3} from "pendle/interfaces/IPActionAddRemoveLiqV3.sol";
import {SwapData, SwapType as SwapTypePendle} from "pendle/router/swap-aggregator/IPSwapAggregator.sol";
import {PoolAction} from "src/proxy/PoolAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "src/proxy/SwapAction.sol";
import {PositionActionTranchess, LeverParams} from "src/proxy/PositionActionTranchess.sol";
import {CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {console} from "forge-std/console.sol";
import {CDPVault} from "src/CDPVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault as IBalancerVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IUniswapV3Router} from "../../vendor/IUniswapV3Router.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {IUniswapV3Router, ExactInputParams, ExactOutputParams, decodeLastToken} from "../../vendor/IUniswapV3Router.sol";

interface IWETH {
    function deposit() external payable;
}

contract MockUniswap {
    function exactInput(ExactInputParams memory params) external returns (uint256) {
        (address assetIn, address assetOut, uint256 amountOut) = abi.decode(params.path, (address, address, uint256));
        IERC20(assetIn).transferFrom(msg.sender, address(this), params.amountIn);
        IERC20(assetOut).transfer(msg.sender, amountOut);
        return amountOut;
    }

    function exactOutput(ExactOutputParams memory params) external returns (uint256) {
        (address assetIn, address assetOut, uint256 amountIn) = abi.decode(params.path, (address, address, uint256));
        IERC20(assetIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(assetOut).transfer(msg.sender, params.amountOut);
        return amountIn;
    }
}

contract PositionActionLeverTranchessTest is TestBase {
    using SafeERC20 for ERC20;
    PoolAction poolAction;
    SwapAction swapAction;
    PositionActionTranchess positionAction;

    PRBProxyRegistry prbProxyRegistry;

    MockUniswap uniswap;
    // PENDLE
    address market = 0xF32e58F92e60f4b0A37A69b95d642A471365EAe8; // Ether.fi PT/SY
    address pendleOwner = 0x1FcCC097db89A86Bfc474A1028F93958295b1Fb7;
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // etherfi staked eth

    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant UNISWAP_V3 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant PENDLE_ROUTER = 0x00000000005BBB0EF59571E58418F9a4357b68A0;

    // TRANCHESS
    address constant TRANCHESS_ROUTER = 0x63BAEe33649E589Cc70435F898671461B624CBCc; // on SCROLL NETWORK
    address STONE = address(0x80137510979822322193FC997d400D5A6C747bf7); // STONE (quoteToken)
    address staYSTONE2 = address(0x09750800529E7BBCd07D4760989B19061E79165B); //baseToken
    address stoneHolderForUni = address(0xAD3d07d431B85B525D81372802504Fa18DBd554c);
    address stoneHolder = address(0xa62F7C8D24A456576DF0f3840cE5A79630c23961);
    address stableSwap = address(0xEC8bFa1D15842D6B670d11777A08c39B09A5FF00); // tranchess stableswap
    address stoneEthChainlink = address(0x0E4d8D665dA14D35444f0eCADc82F78a804A5F95); // stone/eth chainlink feed
    address fund = address(0x4B0D5Fe3C1F58FD68D20651A5bC761553C10D955); // tranchess fund 2 stone
    address lpToken = address(0xD48Cc42e154775f8a65EEa1D6FA1a11A31B09B65); // tranchess lp token (liquidity gauge)
    uint256 settledDay = 1727877600;
    // user
    PRBProxy userProxy;
    address internal user;
    uint256 internal userPk;
    uint256 internal constant NONCE = 0;

    CDPVault vault;

    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    PoolActionParams emptyJoin;
    // univ3
    IUniswapV3Router univ3Router = IUniswapV3Router(UNISWAP_V3);
    IBalancerVault internal constant balancerVault = IBalancerVault(BALANCER_VAULT);
    // kyber
    address kyberRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("scroll"), 10610811);
        usePatchedDeal = true;
        super.setUp();

        prbProxyRegistry = new PRBProxyRegistry();
        poolAction = new PoolAction(address(0), address(0), TRANCHESS_ROUTER);

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        vault = createCDPVault(
            IERC20(lpToken), // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        createGaugeAndSetGauge(address(vault), address(lpToken));
        oracle.updateSpot(address(lpToken), 1 ether);

        uniswap = new MockUniswap();
        vm.prank(stoneHolderForUni);
        ERC20(STONE).transfer(address(uniswap), 10000 ether);
        underlyingToken.mint(address(uniswap), 10000 ether);

        swapAction = new SwapAction(
            balancerVault,
            IUniswapV3Router(address(uniswap)),
            IPActionAddRemoveLiqV3(PENDLE_ROUTER),
            kyberRouter,
            TRANCHESS_ROUTER
        );

        // deploy position actions
        positionAction = new PositionActionTranchess(
            address(flashlender),
            address(swapAction),
            address(poolAction),
            address(vaultRegistry),
            address(mockWETH)
        );
        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));
        deal(user, 10 ether);

        vm.prank(stoneHolder);
        ERC20(STONE).transfer(user, 100 ether);

        vm.prank(address(userProxy));
        IERC20(lpToken).approve(address(user), type(uint256).max);
        vm.prank(address(userProxy));
        IERC20(STONE).approve(address(user), type(uint256).max);
    }

    function test_increaseLever_Tranchess() public {
        test_deposit_with_entry_swap_from_STONE();
        uint256 borrowAmount = 10 ether;

        PoolActionParams memory poolActionParams;

        poolActionParams = PoolActionParams({
            protocol: Protocol.TRANCHESS,
            minOut: 0,
            recipient: address(positionAction),
            args: abi.encode(lpToken, 0, (borrowAmount * 999) / 1000, 0, block.timestamp + 1000)
        });

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(lpToken),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.UNIV3,
                swapType: SwapType.EXACT_IN,
                assetIn: address(underlyingToken),
                amount: borrowAmount,
                limit: 0,
                recipient: address(positionAction),
                residualRecipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(address(underlyingToken), address(STONE), (borrowAmount * 999) / 1000)
            }),
            auxSwap: emptySwap,
            auxAction: poolActionParams
        });

        vm.startPrank(user);
        //  ERC20(STONE).approve(address(userProxy), type(uint256).max);
        // call increaseLever
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(underlyingToken),
                0,
                address(user),
                emptyPermitParams
            )
        );
    }

    function test_decreaseLever_Tranchess() public {
        test_increaseLever_Tranchess();
        (uint256 collateral, uint256 debt, , , , ) = vault.positions(address(userProxy));
        console.log("collateral: ", collateral);
        console.log("debt: ", debt);
        PoolActionParams memory poolActionParams;

        poolActionParams = PoolActionParams({
            protocol: Protocol.TRANCHESS,
            minOut: 0,
            recipient: address(positionAction),
            args: abi.encode(0, lpToken, collateral / 2)
        });

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(lpToken),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.UNIV3,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(STONE),
                amount: debt / 2,
                limit: debt / 2,
                recipient: address(positionAction),
                residualRecipient: address(user),
                deadline: block.timestamp + 100,
                args: abi.encode(address(STONE), address(underlyingToken), ((((debt / 2) * 99) / 100)))
            }),
            auxSwap: emptySwap,
            auxAction: poolActionParams
        });

        assertEq(ERC20(STONE).balanceOf(address(user)), 0);
        vm.startPrank(user);

        uint256 flashloanFee = flashlender.flashFee(address(flashlender.underlyingToken()), debt / 2);
        // call increaseLever
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(positionAction.decreaseLever.selector, leverParams, collateral / 2, address(user))
        );
        (uint256 collateralAfter, uint256 debtAfter, , , , ) = vault.positions(address(userProxy));
        assertApproxEqAbs(collateralAfter, collateral / 2, 1);
        assertEq(debtAfter, debt / 2 + flashloanFee);
        assertApproxEqRel(
            ERC20(STONE).balanceOf(address(user)),
            collateral / 2 - debt / 2,
            0.01 ether,
            "STONE BALANCE"
        );
        assertEq(ERC20(lpToken).balanceOf(address(user)), 0);
        assertEq(ERC20(STONE).balanceOf(address(positionAction)), 0);
        assertEq(ERC20(lpToken).balanceOf(address(positionAction)), 0);
        assertEq(underlyingToken.balanceOf(address(user)) / 1e18, 0);
    }

    function test_deposit_with_entry_swap_from_STONE() public {
        uint256 depositAmount = 100 ether;

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(STONE),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.TRANCHESS_IN,
                swapType: SwapType.EXACT_IN,
                assetIn: address(STONE),
                amount: depositAmount, // amount to swap in
                limit: 99 ether, // min amount of collateral token to receive
                recipient: address(userProxy),
                residualRecipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(lpToken, 0, 100 ether, 0)
            })
        });
        vm.startPrank(user);
        ERC20(STONE).approve(address(userProxy), depositAmount);
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
        assertEq(ERC20(lpToken).balanceOf(address(userProxy)), 0, "failed to deposit");
        (uint256 collateral, uint256 debt, , , , ) = vault.positions(address(userProxy));

        assertApproxEqRel(collateral, 100 ether, 0.01 ether, "invalid collateral amount");
        assertEq(debt, 0);
    }

    function test_withdraw_and_swap_to_STONE() public {
        test_deposit_with_entry_swap_from_STONE();

        (uint256 collateral, , , , , ) = vault.positions(address(userProxy));

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: collateral, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.TRANCHESS_OUT,
                swapType: SwapType.EXACT_IN,
                assetIn: address(lpToken),
                amount: collateral, // amount to swap in
                limit: 98 ether, // min amount of collateral token to receive
                recipient: address(user),
                residualRecipient: address(user),
                deadline: block.timestamp + 100,
                args: abi.encode(0, lpToken, collateral)
            })
        });
        assertEq(ERC20(STONE).balanceOf(address(user)), 0);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        assertEq(ERC20(lpToken).balanceOf(address(userProxy)), 0, "failed to withdraw");
        // (uint256 collateral, uint256 debt, , , , ) = vault.positions(address(userProxy));
        assertGt(ERC20(STONE).balanceOf(address(user)), 0);
        // Little less because of the exiting
        assertApproxEqRel(100 ether, ERC20(STONE).balanceOf(address(user)), 0.01 ether, "invalid stone amount amount");
    }

    function test_multisend_simple_delegatecall() public {
        PoolActionParams memory poolActionParams;

        poolActionParams = PoolActionParams({
            protocol: Protocol.TRANCHESS,
            minOut: 0,
            recipient: address(userProxy),
            args: abi.encode(lpToken, 0, 100 ether, 0, block.timestamp + 1000)
        });

        uint256 depositAmount = 99 ether;
        uint256 borrowAmount = 10 ether;

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(userProxy),
            auxSwap: emptySwap
        });

        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: address(userProxy),
            auxSwap: emptySwap
        });

        address[] memory targets = new address[](3);
        targets[0] = address(poolAction);
        targets[1] = address(positionAction);
        targets[2] = address(vault);

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(poolAction.join.selector, poolActionParams);
        data[1] = abi.encodeWithSelector(
            positionAction.depositAndBorrow.selector,
            address(userProxy),
            address(vault),
            collateralParams,
            creditParams,
            emptyPermitParams
        );
        data[2] = abi.encodeWithSelector(
            CDPVault.modifyCollateralAndDebt.selector,
            address(userProxy),
            address(userProxy),
            address(userProxy),
            0,
            0
        );

        bool[] memory delegateCall = new bool[](3);
        delegateCall[0] = true;
        delegateCall[1] = true;
        delegateCall[2] = false;

        vm.startPrank(user);
        ERC20(STONE).transfer(address(userProxy), 100 ether);
        //ERC20(STONE).approve(address(userProxy), 100 ether);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(positionAction.multisend.selector, targets, data, delegateCall)
        );

        (uint256 collateral, uint256 debt, , , , ) = vault.positions(address(userProxy));
        assertEq(collateral, depositAmount);
        assertEq(debt, borrowAmount);
    }

    function test_repayAndWithdraw() public {
        test_multisend_simple_delegatecall();

        uint256 depositAmount = 99 ether;
        uint256 borrowAmount = 10 ether;
        // build withdraw params
        CollateralParams memory collateralParams;
        CreditParams memory creditParams;
        {
            collateralParams = CollateralParams({
                targetToken: address(lpToken),
                amount: depositAmount,
                collateralizer: address(user),
                auxSwap: emptySwap
            });
            creditParams = CreditParams({amount: borrowAmount, creditor: address(userProxy), auxSwap: emptySwap});
        }
        underlyingToken.approve(address(userProxy), borrowAmount);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdrawAndRepay.selector,
                address(userProxy), // user proxy is the position
                address(vault),
                collateralParams,
                creditParams,
                emptyPermitParams
            )
        );

        (uint256 collateral, uint256 debt, , , , ) = vault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(IERC20(lpToken).balanceOf(address(user)), 99 ether);
    }

    function test_join_with_STONE_and_exit() public {
        PoolActionParams memory poolActionParams;

        poolActionParams = PoolActionParams({
            protocol: Protocol.TRANCHESS,
            minOut: 0,
            recipient: user,
            args: abi.encode(lpToken, 0, 100 ether, 0, block.timestamp + 1000)
        });

        assertEq(ERC20(lpToken).balanceOf(poolActionParams.recipient), 0, "invalid lpToken balance");
        vm.startPrank(user);
        ERC20(STONE).transfer(address(userProxy), 100 ether);
        userProxy.execute(address(poolAction), abi.encodeWithSelector(PoolAction.join.selector, poolActionParams));
        assertGt(ERC20(lpToken).balanceOf(poolActionParams.recipient), 0, "failed to join");

        poolActionParams.args = abi.encode(0, lpToken, ERC20(lpToken).balanceOf(poolActionParams.recipient));

        ERC20(lpToken).transfer(address(userProxy), ERC20(lpToken).balanceOf(user));

        userProxy.execute(address(poolAction), abi.encodeWithSelector(PoolAction.exit.selector, poolActionParams));
        assertEq(ERC20(lpToken).balanceOf(address(poolAction)), 0, "invalid lpToken balance");
        assertEq(ERC20(lpToken).balanceOf(address(userProxy)), 0, "invalid lpToken balance");
        assertApproxEqRel(ERC20(STONE).balanceOf(poolActionParams.recipient), 100 ether, 0.001 ether, "failed to exit");
    }

    function test_transferAndJoin_with_STONE() public {
        PoolActionParams memory poolActionParams;
        PermitParams memory permitParams;

        poolActionParams = PoolActionParams({
            protocol: Protocol.TRANCHESS,
            minOut: 0,
            recipient: user,
            args: abi.encode(lpToken, 0, 100 ether, 0, block.timestamp + 1000)
        });

        vm.startPrank(user);
        ERC20(STONE).approve(address(userProxy), 100 ether);
        // WETH.approve(address(userProxy), type(uint256).max);

        PermitParams[] memory permitParamsArray = new PermitParams[](2);
        permitParamsArray[0] = permitParams;
        permitParamsArray[1] = permitParams;

        assertEq(ERC20(lpToken).balanceOf(poolActionParams.recipient), 0, "failed to join");
        userProxy.execute(
            address(poolAction),
            abi.encodeWithSelector(PoolAction.transferAndJoin.selector, user, permitParamsArray, poolActionParams)
        );
        assertGt(ERC20(lpToken).balanceOf(poolActionParams.recipient), 0, "failed to join");
        console.log("lpToken balance: ", ERC20(lpToken).balanceOf(poolActionParams.recipient));
    }
}
