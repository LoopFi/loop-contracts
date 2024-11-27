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
import {console} from "forge-std/console.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "src/proxy/SwapAction.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault as IBalancerVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IUniswapV3Router} from "../../vendor/IUniswapV3Router.sol";
import {Constants} from "src/vendor/Constants.sol";
import {Commands} from "src/vendor/Commands.sol";
interface IWETH {
    function deposit() external payable;
}

contract PoolActionSpectraTest is TestBase {
    using SafeERC20 for ERC20;
    PoolAction poolAction;
    SwapAction swapAction;
    PRBProxyRegistry prbProxyRegistry;

    // SPECTRA ynETH
    address internal constant SPECTRA_ROUTER = 0x3d20601ac0Ba9CAE4564dDf7870825c505B69F1a;
    address curvePool = address(0x08DA2b1EA8f2098D44C8690dDAdCa3d816c7C0d5); // Spectra ynETH PT-sw-ynETH / sw-ynETH
    address lpTokenTracker = address(0x85F05383f7Cb67f35385F7bF3B74E68F4795CbB9);
    ERC4626 swYnETH = ERC4626(0x6e0dccf49D095F8ea8920A8aF03D236FA167B7E0);
    address pTswYnETH = address(0x57E9EBeB30852D31f99A08E39068d93b0D8FC917);
    address ynETH = address(0x09db87A538BD693E9d08544577d5cCfAA6373A48);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // holders
    address ynETHHolder = address(0xdED077cCF229aBf68882d062d97982f28D6D714D);
    address wethHolder = address(0x57757E3D981446D585Af0D9Ae4d7DF6D64647806);
    // user
    PRBProxy userProxy;
    address internal user;
    uint256 internal userPk;
    uint256 internal constant NONCE = 0;

    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21272674);
        usePatchedDeal = true;
        super.setUp();

        prbProxyRegistry = new PRBProxyRegistry();
        poolAction = new PoolAction(address(0), address(0), address(0), SPECTRA_ROUTER);
        swapAction = new SwapAction(
            IBalancerVault(address(0)),
            IUniswapV3Router(address(0)),
            IPActionAddRemoveLiqV3(address(0)),
            address(0),
            address(0),
            SPECTRA_ROUTER
        );
        // setup user and userProxy
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));
        deal(user, 10 ether);
        vm.label(user, "user");
        vm.label(lpTokenTracker, "lpTokenTracker");
        vm.prank(ynETHHolder);
        ERC20(ynETH).transfer(user, 100 ether);
        vm.prank(wethHolder);
        ERC20(weth).transfer(user, 200 ether);
        vm.startPrank(user);
        ERC20(weth).approve(address(swYnETH), 100 ether);
        swYnETH.deposit(100 ether, user);
    }

    function test_balance() public {
        assertEq(ERC20(ynETH).balanceOf(user), 100 ether, "invalid ynETH balance");
        assertEq(swYnETH.balanceOf(user), 98655211964670624557, "invalid sw-ynETH balance"); // 98.65 sw-ynETH
    }

    function test_join_with_WETH_and_exit() public {
        bytes memory commandsJoin = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.DEPOSIT_ASSET_IN_IBT)),
            bytes1(uint8(Commands.CURVE_ADD_LIQUIDITY))
        );
        bytes[] memory inputsJoin = new bytes[](3);
        inputsJoin[0] = abi.encode(weth, 98 ether);
        inputsJoin[1] = abi.encode(address(swYnETH), Constants.CONTRACT_BALANCE, Constants.ADDRESS_THIS);
        inputsJoin[2] = abi.encode(curvePool, [Constants.CONTRACT_BALANCE, 0], 0, user);
        PoolActionParams memory poolActionParams;

        poolActionParams = PoolActionParams({
            protocol: Protocol.SPECTRA,
            minOut: 0,
            recipient: user,
            args: abi.encode(commandsJoin, inputsJoin, block.timestamp + 1000)
        });

        assertEq(ERC20(lpTokenTracker).balanceOf(poolActionParams.recipient), 0, "invalid lpToken balance");
        vm.startPrank(user);
        ERC20(weth).transfer(address(userProxy), 100 ether);
        userProxy.execute(address(poolAction), abi.encodeWithSelector(PoolAction.join.selector, poolActionParams));
        assertGt(ERC20(lpTokenTracker).balanceOf(poolActionParams.recipient), 0, "failed to join");

        bytes memory commandsExit = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.CURVE_REMOVE_LIQUIDITY_ONE_COIN))
            //   bytes1(uint8(Commands.UNWRAP_VAULT_FROM_4626_ADAPTER))
        );
        bytes[] memory inputsExit = new bytes[](2);
        inputsExit[0] = abi.encode(address(lpTokenTracker), ERC20(lpTokenTracker).balanceOf(user));
        inputsExit[1] = abi.encode(address(curvePool), ERC20(lpTokenTracker).balanceOf(user), 0, 0, SPECTRA_ROUTER);
        // inputsExit[2] = abi.encode(address(swYnETH), Constants.CONTRACT_BALANCE, user);
        poolActionParams.args = abi.encode(commandsExit, inputsExit, address(swYnETH), block.timestamp + 1000);

        ERC20(lpTokenTracker).transfer(address(userProxy), ERC20(lpTokenTracker).balanceOf(user));

        userProxy.execute(address(poolAction), abi.encodeWithSelector(PoolAction.exit.selector, poolActionParams));

        assertEq(ERC20(lpTokenTracker).balanceOf(address(userProxy)), 0, "invalid lpToken balance");
        assertEq(ERC20(lpTokenTracker).balanceOf(address(user)), 0, "invalid lpToken balance");
        assertGt(ERC20(swYnETH).balanceOf(user), 0, "failed to exit");
    }

    function test_transferAndJoin_with_WETH() public {
        PoolActionParams memory poolActionParams;
        PermitParams memory permitParams;

        bytes memory commandsJoin = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.DEPOSIT_ASSET_IN_IBT)),
            bytes1(uint8(Commands.CURVE_ADD_LIQUIDITY))
        );
        bytes[] memory inputsJoin = new bytes[](3);
        inputsJoin[0] = abi.encode(weth, 98 ether);
        inputsJoin[1] = abi.encode(address(swYnETH), Constants.CONTRACT_BALANCE, Constants.ADDRESS_THIS);
        inputsJoin[2] = abi.encode(curvePool, [Constants.CONTRACT_BALANCE, 0], 0, user);

        poolActionParams = PoolActionParams({
            protocol: Protocol.SPECTRA,
            minOut: 0,
            recipient: user,
            args: abi.encode(commandsJoin, inputsJoin, block.timestamp + 1000)
        });

        vm.startPrank(user);
        ERC20(weth).approve(address(userProxy), 100 ether);

        PermitParams[] memory permitParamsArray = new PermitParams[](2);
        permitParamsArray[0] = permitParams;
        permitParamsArray[1] = permitParams;

        assertEq(ERC20(lpTokenTracker).balanceOf(poolActionParams.recipient), 0, "failed to join");
        userProxy.execute(
            address(poolAction),
            abi.encodeWithSelector(PoolAction.transferAndJoin.selector, user, permitParamsArray, poolActionParams)
        );
        assertGt(ERC20(lpTokenTracker).balanceOf(poolActionParams.recipient), 0, "failed to join");
        console.log("lpTokenTracker balance: ", ERC20(lpTokenTracker).balanceOf(poolActionParams.recipient));
    }

    function test_swap_in_and_out_WETH() public {
        uint256 depositAmount = 100 ether;

        bytes memory commandsJoin = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.DEPOSIT_ASSET_IN_IBT)),
            bytes1(uint8(Commands.CURVE_ADD_LIQUIDITY))
        );
        bytes[] memory inputsJoin = new bytes[](3);
        inputsJoin[0] = abi.encode(weth, 100 ether);
        inputsJoin[1] = abi.encode(address(swYnETH), Constants.CONTRACT_BALANCE, Constants.ADDRESS_THIS);
        inputsJoin[2] = abi.encode(curvePool, [Constants.CONTRACT_BALANCE, 0], 0, address(user));

        SwapParams memory swapParams;
        swapParams = SwapParams({
            swapProtocol: SwapProtocol.SPECTRA,
            swapType: SwapType.EXACT_IN,
            assetIn: address(weth),
            amount: depositAmount,
            limit: 99 ether,
            recipient: user,
            residualRecipient: user,
            deadline: block.timestamp,
            args: abi.encode(commandsJoin, inputsJoin, lpTokenTracker, block.timestamp + 1000)
        });

        assertEq(ERC20(lpTokenTracker).balanceOf(swapParams.recipient), 0, "invalid lpTokenTracker balance");
        vm.startPrank(user);
        ERC20(weth).transfer(address(userProxy), 100 ether);
        userProxy.execute(address(swapAction), abi.encodeWithSelector(SwapAction.swap.selector, swapParams));
        assertGt(ERC20(lpTokenTracker).balanceOf(swapParams.recipient), 0, "failed to swap");

        bytes memory commandsExit = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.CURVE_REMOVE_LIQUIDITY_ONE_COIN))
        );
        bytes[] memory inputsExit = new bytes[](2);
        inputsExit[0] = abi.encode(address(lpTokenTracker), ERC20(lpTokenTracker).balanceOf(user));
        inputsExit[1] = abi.encode(address(curvePool), ERC20(lpTokenTracker).balanceOf(user), 0, 0, user);

        swapParams = SwapParams({
            swapProtocol: SwapProtocol.SPECTRA,
            swapType: SwapType.EXACT_IN,
            assetIn: address(lpTokenTracker),
            amount: 0,
            limit: 95 ether,
            recipient: user,
            residualRecipient: user,
            deadline: block.timestamp,
            args: abi.encode(commandsExit, inputsExit, swYnETH, block.timestamp + 1000)
        });
        ERC20(lpTokenTracker).transfer(address(userProxy), ERC20(lpTokenTracker).balanceOf(user));

        userProxy.execute(address(swapAction), abi.encodeWithSelector(SwapAction.swap.selector, swapParams));

        assertGt(ERC20(swYnETH).balanceOf(user), 98 ether, "failed to exit");
    }

    function test_transferAndSwap() public {
        uint256 depositAmount = 100 ether;

        bytes memory commandsJoin = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.DEPOSIT_ASSET_IN_IBT)),
            bytes1(uint8(Commands.CURVE_ADD_LIQUIDITY))
        );
        bytes[] memory inputsJoin = new bytes[](3);
        inputsJoin[0] = abi.encode(weth, 100 ether);
        inputsJoin[1] = abi.encode(address(swYnETH), Constants.CONTRACT_BALANCE, Constants.ADDRESS_THIS);
        inputsJoin[2] = abi.encode(curvePool, [Constants.CONTRACT_BALANCE, 0], 0, address(user));

        SwapParams memory swapParams;
        PermitParams memory permitParams;
        swapParams = SwapParams({
            swapProtocol: SwapProtocol.SPECTRA,
            swapType: SwapType.EXACT_IN,
            assetIn: address(weth),
            amount: depositAmount,
            limit: 99 ether,
            recipient: user,
            residualRecipient: user,
            deadline: block.timestamp,
            args: abi.encode(commandsJoin, inputsJoin, lpTokenTracker, block.timestamp + 1000)
        });
        assertEq(ERC20(lpTokenTracker).balanceOf(swapParams.recipient), 0, "invalid lpTokenTracker balance");
        vm.startPrank(user);
        ERC20(weth).approve(address(userProxy), 100 ether);
        userProxy.execute(
            address(swapAction),
            abi.encodeWithSelector(SwapAction.transferAndSwap.selector, user, permitParams, swapParams)
        );
        assertGt(ERC20(lpTokenTracker).balanceOf(swapParams.recipient), 0, "failed to swap");
    }
}
