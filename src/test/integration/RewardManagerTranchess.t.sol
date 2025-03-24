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
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "src/proxy/SwapAction.sol";
import {PositionAction20} from "src/proxy/PositionAction20.sol";
import {CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {console} from "forge-std/console.sol";
import {CDPVault} from "src/CDPVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault as IBalancerVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IUniswapV3Router} from "../../vendor/IUniswapV3Router.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {RewardManagerTranchess} from "src/tranchess-rewards/RewardManagerTranchess.sol";

interface IWETH {
    function deposit() external payable;
}

interface ILG {
    function syncWithVotingEscrow(address account) external;
}

interface ILiquidityGauge {
    function workingBalanceOf(address account) external view returns (uint256);

    function claimableRewards(
        address account
    )
        external
        returns (
            uint256 chessRewards,
            uint256 bonusRewards,
            uint256 totalRewards,
            uint256 totalBonusRewards,
            uint256 totalRewardsInclBonus,
            uint256 totalBonusRewardsInclBonus
        );
}

contract RewardManagerTranchessTest is TestBase {
    using SafeERC20 for ERC20;
    PoolAction poolAction;
    SwapAction swapAction;
    PositionAction20 positionAction;

    PRBProxyRegistry prbProxyRegistry;
    RewardManagerTranchess rewardManager;
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
    address stoneHolder = address(0xa62F7C8D24A456576DF0f3840cE5A79630c23961);
    address stableSwap = address(0xEC8bFa1D15842D6B670d11777A08c39B09A5FF00); // tranchess stableswap
    address stoneEthChainlink = address(0x0E4d8D665dA14D35444f0eCADc82F78a804A5F95); // stone/eth chainlink feed
    address fund = address(0x4B0D5Fe3C1F58FD68D20651A5bC761553C10D955); // tranchess fund 2 stone
    address lpToken = address(0xD48Cc42e154775f8a65EEa1D6FA1a11A31B09B65); // tranchess lp token (liquidity gauge)
    address chess = address(0x9735fb1126B521A913697A541f768376011bCcF9); // chess rewards
    address chessHolder = address(0x5EA212c549d8CD7006E9BdfdEE6d4C058a75cC7e);
    address lpTokenHolder = address(0x2C29823644760146b7eF3A8F90770579f8095F78);
    uint256 settledDay = 1727877600;
    // user
    PRBProxy userProxy;
    PRBProxy userProxy2;
    address internal user;
    uint256 internal userPk;
    address internal user2;
    uint256 internal userPk2;

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
        vm.createSelectFork(vm.rpcUrl("scroll"), 11743794);
        usePatchedDeal = true;
        super.setUp();

        prbProxyRegistry = new PRBProxyRegistry();
        poolAction = new PoolAction(address(0), address(0), TRANCHESS_ROUTER, address(0));

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

        // RewardManager
        rewardManager = new RewardManagerTranchess(
            address(vault),
            address(lpToken),
            address(prbProxyRegistry),
            address(chess)
        );
        vault.setParameter("rewardManager", address(rewardManager));

        swapAction = new SwapAction(
            balancerVault,
            univ3Router,
            IPActionAddRemoveLiqV3(PENDLE_ROUTER),
            kyberRouter,
            TRANCHESS_ROUTER,
            address(0)
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

        userPk2 = 0x12341235;
        user2 = vm.addr(userPk2);
        userProxy2 = PRBProxy(payable(address(prbProxyRegistry.deployFor(user2))));
        deal(STONE, user, 100 ether);
        deal(lpToken, user, 10 ether);
        deal(lpToken, user2, 10 ether);

        vm.stopPrank();
        vm.prank(address(userProxy));
        IERC20(lpToken).approve(address(user), type(uint256).max);
        vm.prank(address(userProxy));
        IERC20(STONE).approve(address(user), type(uint256).max);
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
            }),
            minAmountOut: 0
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

    function test_withdraw_and_swap_to_STONE_after_1_week() public {
        console.log(
            ILiquidityGauge(address(lpToken)).workingBalanceOf(address(vault)),
            "working balance vault before deposit"
        );

        test_deposit_with_entry_swap_from_STONE();
        (uint256 collateral, , , , , ) = vault.positions(address(userProxy));
        console.log(
            ILiquidityGauge(address(lpToken)).workingBalanceOf(address(vault)),
            "working balance vault after deposit"
        );

        (uint256 chessRewards, uint256 bonusRewards, , , , ) = ILiquidityGauge(address(lpToken)).claimableRewards(
            address(lpTokenHolder)
        );

        vm.stopPrank();
        vm.prank(lpTokenHolder);
        ILG(address(lpToken)).syncWithVotingEscrow(lpTokenHolder);
        console.log("chess rewards after deposit: ", chessRewards);
        (chessRewards, bonusRewards, , , , ) = ILiquidityGauge(address(lpToken)).claimableRewards(
            address(lpTokenHolder)
        );
        console.log("chess rewards after first sync: ", chessRewards);
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 1000);
        // Mock claiming rewards
        // vm.prank(chessHolder);
        // ERC20(chess).transfer(address(vault), 10000 ether);
        deal(address(chess), address(vault), 10000 ether);

        vm.startPrank(user);
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
            }),
            minAmountOut: 0
        });
        vm.stopPrank();
        assertEq(ERC20(STONE).balanceOf(address(user)), 0);
        // No reward yet
        assertEq(ERC20(chess).balanceOf(address(user)), 0);
        console.log(
            ILiquidityGauge(address(lpToken)).workingBalanceOf(address(vault)),
            "working balance vault after some time while deposited"
        );
        vm.prank(lpTokenHolder);
        ILG(address(lpToken)).syncWithVotingEscrow(lpTokenHolder);

        (chessRewards, bonusRewards, , , , ) = ILiquidityGauge(address(lpToken)).claimableRewards(address(vault));
        console.log("chess rewards after some time: ", chessRewards);
        vm.startPrank(user);
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
        console.log(
            ILiquidityGauge(address(lpToken)).workingBalanceOf(address(vault)),
            "working balance vault after some time and withdraw"
        );
        assertEq(ERC20(lpToken).balanceOf(address(userProxy)), 0, "failed to withdraw");

        assertGt(ERC20(STONE).balanceOf(address(user)), 0);
        // Little less because of the exiting
        assertApproxEqRel(100 ether, ERC20(STONE).balanceOf(address(user)), 0.01 ether, "invalid stone amount amount");

        assertApproxEqRel(ERC20(chess).balanceOf(address(user)), 10000 ether, 0.000000001 ether, "failed to get chess");
        assertApproxEqAbs(ERC20(chess).balanceOf(address(vault)), 0, 100);
    }

    function test_2_deposits_and_same_withdraw() public {
        vm.startPrank(user);
        uint256 depositAmount = 10 ether;

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        ERC20(lpToken).approve(address(userProxy), depositAmount);
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
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);

        vm.startPrank(user2);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user2),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        ERC20(lpToken).approve(address(userProxy2), depositAmount);
        userProxy2.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy2),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);
        // vm.prank(chessHolder);
        // ERC20(chess).transfer(address(vault), 10000 ether);
        deal(address(chess), address(vault), 10000 ether);

        vm.startPrank(user);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

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
        vm.stopPrank();
        assertEq(ERC20(chess).balanceOf(address(user)), 5000 ether, "failed to get chess");
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user2),
            auxSwap: emptySwap,
            minAmountOut: 0
        });
        vm.startPrank(user2);
        userProxy2.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy2),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        assertEq(ERC20(chess).balanceOf(address(user2)), 5000 ether, "failed to get chess user 2");
    }

    function fix_test_2_deposits_and_different_withdraw_time() public {
        vm.startPrank(user);
        uint256 depositAmount = 10 ether;

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        ERC20(lpToken).approve(address(userProxy), depositAmount);
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
        // Advance but not rewards
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);

        vm.startPrank(user2);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user2),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        ERC20(lpToken).approve(address(userProxy2), depositAmount);
        userProxy2.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy2),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);
        // vm.prank(chessHolder);
        // ERC20(chess).transfer(address(vault), 10000 ether);
        deal(address(chess), address(vault), 10000 ether);

        vm.startPrank(user);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

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
        vm.stopPrank();
        assertEq(ERC20(chess).balanceOf(address(user)), 5000 ether, "failed to get chess");
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user2),
            auxSwap: emptySwap,
            minAmountOut: 0
        });
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);

        // vm.prank(chessHolder);
        // ERC20(chess).transfer(address(vault), 1000 ether);
        deal(address(chess), address(vault), 1000 ether);

        vm.startPrank(user2);
        userProxy2.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy2),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        assertEq(ERC20(chess).balanceOf(address(user2)), 6000 ether, "failed to get chess user 2");
    }

    function test_2_deposits_and_3_withdraws() public {
        vm.startPrank(user);
        uint256 depositAmount = 10 ether;

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        ERC20(lpToken).approve(address(userProxy), depositAmount);
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
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);
        vm.startPrank(user2);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user2),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        ERC20(lpToken).approve(address(userProxy2), depositAmount);
        userProxy2.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy2),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);
        deal(address(chess), address(vault), 10000 ether);
        
        vm.startPrank(user);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount / 2,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

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
        vm.stopPrank();
        assertEq(ERC20(chess).balanceOf(address(user)), 5000 ether, "failed to get chess");
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);

        vm.startPrank(user);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount / 2,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

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
        vm.stopPrank();
        assertEq(ERC20(chess).balanceOf(address(user)), 5000 ether, "failed to get full chess");

        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 100000);
        vm.startPrank(user2);
        collateralParams = CollateralParams({
            targetToken: address(lpToken),
            amount: depositAmount,
            collateralizer: address(user2),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        userProxy2.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy2),
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        vm.stopPrank();
        assertEq(ERC20(chess).balanceOf(address(user2)), 5000 ether, "failed to get chess user 2");
    }
}
