// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";
import {PRBProxyRegistry} from "prb-proxy/PRBProxyRegistry.sol";
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

import { IPActionSwapPTV3} from "pendle/interfaces/IPActionSwapPTV3.sol";
import { IPActionAddRemoveLiqV3} from "pendle/interfaces/IPActionAddRemoveLiqV3.sol";
import {Test} from "forge-std/Test.sol";
import {ActionMarketCoreStatic} from "pendle/offchain-helpers/router-static/base/ActionMarketCoreStatic.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {IUniswapV3Router, decodeLastToken, UniswapV3Router_decodeLastToken_invalidPath} from "../../vendor/IUniswapV3Router.sol";
import {IVault as IBalancerVault} from "../../vendor/IBalancerVault.sol";
import {IPActionAddRemoveLiqV3} from "pendle/interfaces/IPActionAddRemoveLiqV3.sol";

contract PoolActionPendleTest is ActionMarketCoreStatic, Test {
    using SafeERC20 for ERC20;

    address wstETH_bb_a_WETH_BPTl = 0x41503C9D499ddbd1dCdf818a1b05e9774203Bf46;
    bytes32 poolId = 0x41503c9d499ddbd1dcdf818a1b05e9774203bf46000000000000000000000594;

    address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant bbaweth = 0xbB6881874825E60e1160416D6C426eae65f2459E;

    // PENDLE
    address market = 0xF32e58F92e60f4b0A37A69b95d642A471365EAe8; // Ether.fi PT/SY
    address pendleOwner = 0x1FcCC097db89A86Bfc474A1028F93958295b1Fb7;
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    // Pendle yieldContractFactory = Pendle(address(0xdF3601014686674e53d1Fa52F7602525483F9122));
    // Pendle marketContractFactory = Pendle(address(0x1A6fCc85557BC4fB7B534ed835a03EF056552D52));
    address internal constant PENDLE_ROUTER= 0x00000000005BBB0EF59571E58418F9a4357b68A0;

    // user
    PRBProxy userProxy;
    address internal user;
    uint256 internal userPk;
    uint256 internal constant NONCE = 0;
    
    PRBProxyRegistry internal prbProxyRegistry;
    PoolAction internal poolAction;
    SwapAction internal swapAction;



    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19356381); // 03/03/2024 18:18:47 UTC
        //super.setUp();
       
      ///  vm.label(BALANCER_VAULT, "balancer");
        vm.label(wstETH, "wstETH");
        vm.label(bbaweth, "bbaweth");
        vm.label(wstETH_bb_a_WETH_BPTl, "wstETH-bb-a-WETH-BPTl");
        
        prbProxyRegistry = new PRBProxyRegistry();
        poolAction = new PoolAction(address(0), PENDLE_ROUTER);
        swapAction = new SwapAction(IBalancerVault(address(0)),IUniswapV3Router(address(0)), IPActionAddRemoveLiqV3(PENDLE_ROUTER));
        
        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));
        deal(user, 10 ether);
        // vm.startPrank(user);
        // ERC20(wstETH).approve(address(permit2), type(uint256).max);
        // ERC20(bbaweth).approve(address(permit2), type(uint256).max);
        // vm.stopPrank();
    }

    function test_join_and_exit_Pendle_Ether() public {
        PoolActionParams memory poolActionParams;
        PermitParams memory permitParams;

        ApproxParams memory approxParams;
        TokenInput memory tokenInput;
        LimitOrderData memory limitOrderData;

        approxParams = ApproxParams({
            guessMin: 0,
            guessMax: 15519288115338392367,
            guessOffchain: 0,
            maxIteration: 12,
            eps: 10000000000000000
        });

        tokenInput.netTokenIn = 5 ether;
        
        poolActionParams = PoolActionParams({
            protocol: Protocol.PENDLE,
            minOut: 0,
            recipient: user,
            args: abi.encode(
                market,
                approxParams,
                tokenInput,
                limitOrderData
            )
        });

        vm.startPrank(user);
    
        userProxy.execute{value: 5 ether}(
            address(poolAction),
            abi.encodeWithSelector(
                PoolAction.join.selector,
                poolActionParams
            )
        );
  
    
       assertGt(ERC20(market).balanceOf(poolActionParams.recipient) , 0 , "failed to join");
       assertEq(ERC20(weETH).balanceOf(poolActionParams.recipient) , 0, "invalid weETH balance");
       
       poolActionParams.args = abi.encode(market,ERC20(market).balanceOf(poolActionParams.recipient),weETH);

       ERC20(market).approve(address(userProxy), type(uint256).max);

       userProxy.execute(
            address(poolAction),
            abi.encodeWithSelector(
                PoolAction.exit.selector,
                poolActionParams
            )
        );

        assertEq(ERC20(market).balanceOf(poolActionParams.recipient) , 0, "failed to redeem");
        assertGt(ERC20(weETH).balanceOf(poolActionParams.recipient) , 0, "failed to redeem");
        assertEq(user.balance, 5 ether, "invalid user balance");
    }

    function test_swap_Pendle_In_And_Out_Ether() public {
        SwapParams memory swapParams;
        PermitParams memory permitParams;

        ApproxParams memory approxParams;
        TokenInput memory tokenInput;
        LimitOrderData memory limitOrderData;

        approxParams = ApproxParams({
            guessMin: 0,
            guessMax: 15519288115338392367,
            guessOffchain: 0,
            maxIteration: 12,
            eps: 10000000000000000
        });

        tokenInput.netTokenIn = 5 ether;
        
        swapParams = SwapParams({
            swapProtocol: SwapProtocol.PENDLE_IN,
            swapType: SwapType.EXACT_IN,
            assetIn : address(0),
            amount: tokenInput.netTokenIn,
            limit: 0,
            recipient: user,
            deadline: 0,
            args: abi.encode(
                market,
                approxParams,
                tokenInput,
                limitOrderData
            )
        });

        vm.startPrank(user);
    
        userProxy.execute{value: 5 ether}(
            address(swapAction),
            abi.encodeWithSelector(
                SwapAction.swap.selector,
                swapParams
            )
        );


        assertEq(ERC20(weETH).balanceOf(swapParams.recipient) , 0, "failed to swap/join");
        assertEq(user.balance, 5 ether, "invalid user balance");
 
        
        uint256 lpIn = ERC20(market).balanceOf(user);

        swapParams = SwapParams({
            swapProtocol: SwapProtocol.PENDLE_OUT,
            swapType: SwapType.EXACT_IN,
            assetIn : market,
            amount: ERC20(market).balanceOf(user),
            limit: 0,
            recipient: user,
            deadline: 0,
            args: abi.encode(
                market,
                lpIn,
                weETH
            )
        });


        ERC20(market).approve(address(userProxy), type(uint256).max);

        userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(
                SwapAction.swap.selector,
                swapParams
            )
        );

        assertEq(ERC20(market).balanceOf(swapParams.recipient) , 0, "failed to swap/redeem");
        assertGt(ERC20(weETH).balanceOf(swapParams.recipient) , 0, "failed to swap/redeem");
    }

    function getForkBlockNumber() internal virtual pure returns (uint256){
        return 19356381; 
    }
}