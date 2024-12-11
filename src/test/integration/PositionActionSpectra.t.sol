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
import {PositionAction20} from "src/proxy/PositionAction20.sol";
import {CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {console} from "forge-std/console.sol";
import {CDPVault} from "src/CDPVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault as IBalancerVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IUniswapV3Router} from "../../vendor/IUniswapV3Router.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {Constants} from "src/vendor/Constants.sol";
import {Commands} from "src/vendor/Commands.sol";

interface IWETH {
    function deposit() external payable;
}

contract PositionActionSpectraTest is TestBase {
    using SafeERC20 for ERC20;
    PoolAction poolAction;
    SwapAction swapAction;
    PositionAction20 positionAction;

    PRBProxyRegistry prbProxyRegistry;

    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant UNISWAP_V3 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant PENDLE_ROUTER = 0x00000000005BBB0EF59571E58418F9a4357b68A0;

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

    CDPVault vault;

    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    // univ3
    IUniswapV3Router univ3Router = IUniswapV3Router(UNISWAP_V3);
    IBalancerVault internal constant balancerVault = IBalancerVault(BALANCER_VAULT);
    // kyber
    address kyberRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    function setUp() public virtual override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21272674);
        usePatchedDeal = true;
        super.setUp();

        prbProxyRegistry = new PRBProxyRegistry();
        poolAction = new PoolAction(address(0), address(0), address(0), SPECTRA_ROUTER);

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        vault = createCDPVault(
            IERC20(lpTokenTracker), // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        createGaugeAndSetGauge(address(vault), address(lpTokenTracker));
        oracle.updateSpot(address(lpTokenTracker), 1 ether);

        swapAction = new SwapAction(
            balancerVault,
            univ3Router,
            IPActionAddRemoveLiqV3(PENDLE_ROUTER),
            kyberRouter,
            address(0),
            SPECTRA_ROUTER
        );

        // deploy position actions
        positionAction = new PositionAction20(
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

        vm.prank(wethHolder);
        ERC20(weth).transfer(user, 200 ether);
    }

    function test_deposit_with_entry_swap_from_WETH() public {
        uint256 depositAmount = 100 ether;

        bytes memory commandsJoin = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.DEPOSIT_ASSET_IN_IBT)),
            bytes1(uint8(Commands.CURVE_ADD_LIQUIDITY))
        );
        bytes[] memory inputsJoin = new bytes[](3);
        inputsJoin[0] = abi.encode(weth, 100 ether);
        inputsJoin[1] = abi.encode(address(swYnETH), Constants.CONTRACT_BALANCE, Constants.ADDRESS_THIS);
        inputsJoin[2] = abi.encode(curvePool, [Constants.CONTRACT_BALANCE, 0], 0, address(userProxy));

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(weth),
            amount: 0, // not used for swaps
            collateralizer: address(user),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.SPECTRA,
                swapType: SwapType.EXACT_IN,
                assetIn: address(weth),
                amount: depositAmount, // amount to swap in
                limit: 98 ether, // min amount of collateral token to receive
                recipient: address(userProxy),
                residualRecipient: address(userProxy),
                deadline: block.timestamp + 100,
                args: abi.encode(commandsJoin, inputsJoin, lpTokenTracker, block.timestamp + 1000)
            }),
            minAmountOut: 0
        });
        vm.startPrank(user);
        ERC20(weth).approve(address(userProxy), depositAmount);
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
        assertEq(ERC20(lpTokenTracker).balanceOf(address(userProxy)), 0, "failed to deposit");

        (uint256 collateral, uint256 debt, , , , ) = vault.positions(address(userProxy));

        assertApproxEqRel(collateral, 49.5 ether, 0.01 ether, "invalid collateral amount");
        assertEq(debt, 0);
    }

    function test_withdraw_and_swap_to_SwYnETH() public {
        test_deposit_with_entry_swap_from_WETH();

        (uint256 collateral, , , , , ) = vault.positions(address(userProxy));
        bytes memory commandsExit = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.CURVE_REMOVE_LIQUIDITY_ONE_COIN))
        );
        bytes[] memory inputsExit = new bytes[](2);
        inputsExit[0] = abi.encode(address(lpTokenTracker), collateral);
        inputsExit[1] = abi.encode(address(curvePool), collateral, 0, 0, user);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(lpTokenTracker),
            amount: collateral,
            collateralizer: address(userProxy),
            auxSwap: SwapParams({
                swapProtocol: SwapProtocol.SPECTRA,
                swapType: SwapType.EXACT_IN,
                assetIn: address(lpTokenTracker),
                amount: 0,
                limit: 95 ether,
                recipient: user,
                residualRecipient: user,
                deadline: block.timestamp,
                args: abi.encode(commandsExit, inputsExit, swYnETH, block.timestamp + 1000)
            }),
            minAmountOut: 0
        });
        assertEq(ERC20(swYnETH).balanceOf(address(user)), 0);
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
        assertEq(ERC20(lpTokenTracker).balanceOf(address(userProxy)), 0, "failed to withdraw");
        // (uint256 collateral, uint256 debt, , , , ) = vault.positions(address(userProxy));
        assertGt(ERC20(swYnETH).balanceOf(address(user)), 0);
        // Little less because of the exiting
        assertApproxEqRel(98 ether, ERC20(swYnETH).balanceOf(address(user)), 0.01 ether, "invalid stone amount amount");
    }
}
