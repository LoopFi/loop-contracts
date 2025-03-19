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
import {PositionAction, CollateralParams, CreditParams, LeverParams} from "../../proxy/PositionAction.sol";
import {PositionActionPenpie} from "../../proxy/PositionActionPenpie.sol";
import {PoolAction, Protocol, PoolActionParams} from "../../proxy/PoolAction.sol";
import {TokenInput, LimitOrderData} from "pendle/interfaces/IPAllActionTypeV3.sol";
import {ApproxParams} from "pendle/router/base/MarketApproxLib.sol";
import {SwapData, SwapType as SwapTypePendle} from "pendle/router/swap-aggregator/IPSwapAggregator.sol";

contract PositionActionPenpie_Lever_Test is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault penpieVault_STETH;

    // actions
    PositionActionPenpie positionAction;

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;
    bytes32[] pendlePoolIdArrayIn;
    bytes32[] pendlePoolIdArrayOut;

    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    bytes32 wstETHPoolId = 0x93d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2; // wstETH/WETH
    address pendleDepositHelper = address(0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4);
    address receiptToken = address(0x9dfaacc97aF3b4FcFFf62213F6913E1A848E8881);
    function setUp() public virtual override {
        usePatchedDeal = true;
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        penpieVault_STETH = createCDPVault(
            ERC20(receiptToken), // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        // configure oracle spot prices
        oracle.updateSpot(address(receiptToken), 3500 ether);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));
        deal(user, 10 ether);

        createGaugeAndSetGauge(address(penpieVault_STETH), address(receiptToken));

        // deploy position actions
        positionAction = new PositionActionPenpie(
            address(flashlender),
            address(swapAction),
            address(poolAction),
            address(vaultRegistry),
            address(mockWETH),
            address(pendleDepositHelper)
        );

        // pendlePoolIdArrayIn.push(stablePoolId);
        pendlePoolIdArrayIn.push(weightedMockWethPoolId);

        pendlePoolIdArrayOut.push(weightedMockWethPoolId);
        //     pendlePoolIdArrayOut.push(wethDaiPoolId);
        pendlePoolIdArrayOut.push(wstETHPoolId);

        vm.label(user, "user");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(penpieVault_STETH), "penpieVault_STETH");
        vm.label(address(positionAction), "positionAction");
    }

    function test_increaseLever() public {
        uint256 upFrontUnderliers = 100 ether;
        uint256 borrowAmount = 17600 ether;

        deal(address(PENDLE_LP_STETH2), user, upFrontUnderliers);

        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(underlyingToken);
        assets[1] = address(WETH);

        ApproxParams memory approxParams;
        TokenInput memory tokenInput;
        LimitOrderData memory limitOrderData;
        SwapData memory swapData;
        swapData.swapType = SwapTypePendle.ETH_WETH;

        approxParams = ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 10000000000000000
        });

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(penpieVault_STETH),
            collateralToken: address(PENDLE_LP_STETH2),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(underlyingToken),
                amount: borrowAmount,
                limit: 0,
                recipient: address(positionAction),
                residualRecipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(pendlePoolIdArrayIn, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        // Update recipient to simulate the swap
        leverParams.primarySwap.recipient = address(swapAction);
        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);
        // Re-update recipient
        leverParams.primarySwap.recipient = address(positionAction);
        // Update tokenIn (WETH) with the exact amount
        tokenInput.netTokenIn = expectedAmountOut;
        tokenInput.tokenIn = address(WETH);
        tokenInput.swapData = swapData;

        leverParams.auxAction = PoolActionParams(
            Protocol.PENDLE,
            0,
            address(positionAction),
            abi.encode(address(PENDLE_LP_STETH2), approxParams, tokenInput, limitOrderData)
        );

        vm.startPrank(user);
        PENDLE_LP_STETH2.approve(address(userProxy), type(uint256).max);

        // call increaseLever
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(PENDLE_LP_STETH2),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );
        (, uint256 normalDebt, , , , ) = penpieVault_STETH.positions(address(userProxy));

        // assert normalDebt is the same as the amount of stablecoin borrowed
        uint256 flashloanFee = flashlender.flashFee(address(flashlender.underlyingToken()), borrowAmount);
        assertEq(normalDebt, borrowAmount + flashloanFee, "Not correct normal debt amount");

        // assert leverAction position is empty
        (uint256 lcollateral, uint256 lnormalDebt, , , , ) = penpieVault_STETH.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);

        // No WETH left in positionAction
        assertEq(WETH.balanceOf(address(positionAction)), 0, "WETH left in position action");
    }

    function test_decreaseLever_Penpie() public {
        // Lever Position First
        uint256 upFrontUnderliers = 100 ether;
        uint256 borrowAmount = 17600 ether;

        deal(address(PENDLE_LP_STETH2), user, upFrontUnderliers);
        // build increase lever params
        address[] memory assets = new address[](2);
        assets[0] = address(underlyingToken);
        assets[1] = address(WETH);

        ApproxParams memory approxParams;
        TokenInput memory tokenInput;
        SwapData memory swapData;
        swapData.swapType = SwapTypePendle.ETH_WETH;

        approxParams = ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 10000000000000000
        });

        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(penpieVault_STETH),
            collateralToken: address(PENDLE_LP_STETH2),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_IN,
                assetIn: address(underlyingToken),
                amount: borrowAmount,
                limit: 0,
                recipient: address(positionAction),
                residualRecipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(pendlePoolIdArrayIn, assets)
            }),
            auxSwap: emptySwap,
            auxAction: emptyJoin
        });

        // Update recipient to simulate the swap
        leverParams.primarySwap.recipient = address(swapAction);
        uint256 expectedAmountOut = _simulateBalancerSwap(leverParams.primarySwap);
        // Re-update recipient
        leverParams.primarySwap.recipient = address(positionAction);
        // Update tokenIn (WETH) with the exact amount
        tokenInput.netTokenIn = expectedAmountOut;
        tokenInput.tokenIn = address(WETH);
        tokenInput.swapData = swapData;

        vm.startPrank(user);
        PENDLE_LP_STETH2.approve(address(userProxy), type(uint256).max);

        // call increaseLever
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                address(PENDLE_LP_STETH2),
                upFrontUnderliers,
                address(user),
                emptyPermitParams
            )
        );

        // NOW we can decrease the lever
        (uint256 initialCollateral, uint256 initialNormalDebt, , , , ) = penpieVault_STETH.positions(
            address(userProxy)
        );

        uint256 repayAmount = 2.5 ether; // amount of stablecoin to repay
        uint256 lpToRedeem = 3 ether; // LP AMOUNT to Redeem for underlying and sell it for stablecoin

        uint256 flashloanFee = flashlender.flashFee(address(flashlender.underlyingToken()), repayAmount);

        assets = new address[](3);
        assets[0] = address(underlyingToken);
        assets[1] = address(WETH);
        assets[2] = address(wstETH);

        leverParams = LeverParams({
            position: address(userProxy),
            vault: address(penpieVault_STETH),
            collateralToken: address(wstETH),
            primarySwap: SwapParams({
                swapProtocol: SwapProtocol.BALANCER,
                swapType: SwapType.EXACT_OUT,
                assetIn: address(wstETH),
                amount: repayAmount, // exact amount of stablecoin to receive
                limit: lpToRedeem, // exact amount of PENDLE LP to redeem
                recipient: address(positionAction),
                residualRecipient: address(positionAction),
                deadline: block.timestamp + 100,
                args: abi.encode(pendlePoolIdArrayOut, assets)
            }),
            auxSwap: emptySwap,
            auxAction: PoolActionParams(
                Protocol.PENDLE,
                0,
                address(positionAction),
                abi.encode(address(PENDLE_LP_STETH2), lpToRedeem, address(wstETH))
            )
        });
        vm.stopPrank();
        uint256 expectedAmountIn = _simulateBalancerSwap(leverParams.primarySwap);

        assertEq(0, ERC20(wstETH).balanceOf(address(userProxy)));

        // call decreaseLever
        vm.startPrank(user);
        PENDLE_LP_STETH2.approve(address(userProxy), type(uint256).max);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector, // function
                leverParams, // lever params
                lpToRedeem, // collateral to decrease by
                address(userProxy) // residualRecipient
            )
        );

        (uint256 collateral, uint256 normalDebt, , , , ) = penpieVault_STETH.positions(address(userProxy));

        // assert new collateral amount is the same as initialCollateral minus the amount of PENDLE LP we swapped for stablecoin
        assertEq(collateral, initialCollateral - lpToRedeem);

        // assert new normalDebt is the same as initialNormalDebt minus the amount of stablecoin we received from swapping PENDLE LP
        assertEq(normalDebt, initialNormalDebt - repayAmount + flashloanFee);

        // assert that the left over was transfered to the user proxy
        assertGt(ERC20(wstETH).balanceOf(address(userProxy)), 0);
        assertEq(ERC20(wstETH).balanceOf(address(positionAction)), 0);
        assertEq(ERC20(wstETH).balanceOf(address(user)), 0);
        assertEq(ERC20(wstETH).balanceOf(address(penpieVault_STETH)), 0);
        assertEq(ERC20(wstETH).balanceOf(address(poolAction)), 0);
        assertEq(ERC20(wstETH).balanceOf(address(swapAction)), 0);

        // TODO: use a preview from Pendle for this
        assertEq(5477435663994785528 - expectedAmountIn, ERC20(wstETH).balanceOf(address(userProxy)), "balance");

        // ensure there isn't any left over debt or collateral from using leverAction
        (uint256 lcollateral, uint256 lnormalDebt, , , , ) = penpieVault_STETH.positions(address(positionAction));
        assertEq(lcollateral, 0);
        assertEq(lnormalDebt, 0);
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 19356381;
    }
}
