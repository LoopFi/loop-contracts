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
import {ApproxParams} from "pendle/interfaces/IPAllActionTypeV3.sol";

import {TestBase} from "src/test/TestBase.sol";
import {Test} from "forge-std/Test.sol";
import {ActionMarketCoreStatic} from "pendle/offchain-helpers/router-static/base/ActionMarketCoreStatic.sol";
import {IUniswapV3Router, decodeLastToken, UniswapV3Router_decodeLastToken_invalidPath} from "../../vendor/IUniswapV3Router.sol";
import {IVault as IBalancerVault} from "../../vendor/IBalancerVault.sol";
import {IPActionAddRemoveLiqV3} from "pendle/interfaces/IPActionAddRemoveLiqV3.sol";
import {SwapData, SwapType as SwapTypePendle} from "pendle/router/swap-aggregator/IPSwapAggregator.sol";
import {PoolAction} from "src/proxy/PoolAction.sol";
import {console} from "forge-std/console.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "src/proxy/SwapAction.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault as IBalancerVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IUniswapV3Router} from "../../vendor/IUniswapV3Router.sol";

interface IWETH {
    function deposit() external payable;
}

contract PoolActionTranchessTest is TestBase {
    using SafeERC20 for ERC20;
    PoolAction poolAction;
    SwapAction swapAction;
    PRBProxyRegistry prbProxyRegistry;

    // PENDLE
    address market = 0xF32e58F92e60f4b0A37A69b95d642A471365EAe8; // Ether.fi PT/SY
    address pendleOwner = 0x1FcCC097db89A86Bfc474A1028F93958295b1Fb7;
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // etherfi staked eth

    // TRANCHESS
    address constant TRANCHESS_ROUTER = 0x63BAEe33649E589Cc70435F898671461B624CBCc; // on SCROLL NETWORK
    address STONE = address(0x80137510979822322193FC997d400D5A6C747bf7); // STONE (quoteToken)
    address staYSTONE2 = address(0x09750800529E7BBCd07D4760989B19061E79165B); //baseToken
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

    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("scroll"), 10610811);
        usePatchedDeal = true;
        super.setUp();

        prbProxyRegistry = new PRBProxyRegistry();
        poolAction = new PoolAction(address(0), address(0), TRANCHESS_ROUTER, address(0));
        swapAction = new SwapAction(
            IBalancerVault(address(0)),
            IUniswapV3Router(address(0)),
            IPActionAddRemoveLiqV3(address(0)),
            address(0),
            TRANCHESS_ROUTER,
            address(0)
        );
        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));
        deal(user, 10 ether);

        vm.prank(stoneHolder);
        ERC20(STONE).transfer(user, 100 ether);
    }

    function test_balance() public {
        assertEq(ERC20(STONE).balanceOf(user), 100 ether, "invalid STONE balance");
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

    function test_swap_in_and_out_STONE() public {
        SwapParams memory swapParams;
        swapParams = SwapParams({
            swapProtocol: SwapProtocol.TRANCHESS_IN,
            swapType: SwapType.EXACT_IN,
            assetIn: address(0),
            amount: 0,
            limit: 99 ether,
            recipient: user,
            residualRecipient: user,
            deadline: block.timestamp,
            args: abi.encode(lpToken, 0, 100 ether, 0)
        });

        assertEq(ERC20(lpToken).balanceOf(swapParams.recipient), 0, "invalid lpToken balance");
        vm.startPrank(user);
        ERC20(STONE).transfer(address(userProxy), 100 ether);
        userProxy.execute(address(swapAction), abi.encodeWithSelector(SwapAction.swap.selector, swapParams));
        assertGt(ERC20(lpToken).balanceOf(swapParams.recipient), 0, "failed to swap");

        swapParams = SwapParams({
            swapProtocol: SwapProtocol.TRANCHESS_OUT,
            swapType: SwapType.EXACT_IN,
            assetIn: address(0),
            amount: 0,
            limit: 99 ether,
            recipient: user,
            residualRecipient: user,
            deadline: block.timestamp,
            args: abi.encode(0, lpToken, ERC20(lpToken).balanceOf(user), 0)
        });
        ERC20(lpToken).transfer(address(userProxy), ERC20(lpToken).balanceOf(user));

        userProxy.execute(address(swapAction), abi.encodeWithSelector(SwapAction.swap.selector, swapParams));
        assertEq(ERC20(lpToken).balanceOf(address(swapAction)), 0, "invalid lpToken balance");
        assertEq(ERC20(lpToken).balanceOf(address(userProxy)), 0, "invalid lpToken balance");
        assertApproxEqRel(ERC20(STONE).balanceOf(swapParams.recipient), 100 ether, 0.001 ether, "failed to exit");
    }

    function test_transferAndSwap() public {
        SwapParams memory swapParams;
        PermitParams memory permitParams;
        swapParams = SwapParams({
            swapProtocol: SwapProtocol.TRANCHESS_IN,
            swapType: SwapType.EXACT_IN,
            assetIn: STONE,
            amount: 0,
            limit: 99 ether,
            recipient: user,
            residualRecipient: user,
            deadline: block.timestamp,
            args: abi.encode(lpToken, 0, 100 ether, 0)
        });
        assertEq(ERC20(lpToken).balanceOf(swapParams.recipient), 0, "invalid lpToken balance");
        vm.startPrank(user);
        ERC20(STONE).transfer(address(userProxy), 100 ether);
        userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(SwapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        assertGt(ERC20(lpToken).balanceOf(swapParams.recipient), 0, "failed to swap");
    }
}
