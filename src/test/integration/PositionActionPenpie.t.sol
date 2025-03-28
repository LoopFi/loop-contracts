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
import {PositionActionPenpie} from "../../proxy/PositionActionPenpie.sol";

import {TokenInput, LimitOrderData} from "pendle/interfaces/IPAllActionTypeV3.sol";
import {ApproxParams} from "pendle/router/math/MarketApproxLibV2.sol";
import {IPendleMarketDepositHelper} from "src/interfaces/IPendleMarketDepositHelper.sol";
contract PositionActionPenpieTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault pendleVault_STETH;

    // actions
    PositionActionPenpie positionAction;

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    address PENDLE_LP_ETHERFI = 0xF32e58F92e60f4b0A37A69b95d642A471365EAe8; // Ether.fi PT/SY
    address pendleOwner = 0x1FcCC097db89A86Bfc474A1028F93958295b1Fb7;
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address pendleDepositHelper = address(0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4);
    address receiptToken = address(0x9dfaacc97aF3b4FcFFf62213F6913E1A848E8881);
    function setUp() public virtual override {
        usePatchedDeal = true;
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        pendleVault_STETH = createCDPVault(
            ERC20(receiptToken), // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        createGaugeAndSetGauge(address(pendleVault_STETH), receiptToken);

        // configure oracle spot prices
        oracle.updateSpot(receiptToken, 3500 ether);

        // setup user and userProxy
        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        // deploy position actions
        positionAction = new PositionActionPenpie(
            address(flashlender),
            address(swapAction),
            address(poolAction),
            address(vaultRegistry),
            address(mockWETH),
            address(pendleDepositHelper)
        );

        vm.label(user, "user");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(PENDLE_LP_STETH), "PENDLE_LP_STETH");
        vm.label(address(pendleVault_STETH), "pendleVault_STETH");
        vm.label(address(positionAction), "positionAction");
    }

    function test_deploy_pENPIE_position_action() public {
        assertTrue(address(positionAction) != address(0));
    }

    function test_deposit_PENPIE_LP_stETH() public {
        uint256 depositAmount = 100 ether;

        deal(address(PENDLE_LP_STETH2), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH2),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        vm.prank(user);
        PENDLE_LP_STETH2.approve(address(userProxy), depositAmount);

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

    function test_deposit_from_proxy_collateralizer_PENPIE() public {
        uint256 depositAmount = 100 ether;

        deal(address(PENDLE_LP_STETH2), address(userProxy), depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH2),
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

    function test_withdraw_PENDLE() public {
        // deposit PENDLE_STETH to vault
        uint256 initialDeposit = 100 ether;
        _deposit(userProxy, address(pendleVault_STETH), initialDeposit);

        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH2),
            amount: initialDeposit,
            collateralizer: address(user),
            auxSwap: auxSwap,
            minAmountOut: 0
        });

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
    }

    function test_borrow_PENDLE() public {
        // deposit pendleVault_STETH to vault
        uint256 initialDeposit = 100 ether;
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
                targetToken: address(PENDLE_LP_STETH2),
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
        assertEq(PENDLE_LP_STETH2.balanceOf(user), depositAmount);
    }

    // MULTISEND

    function test_multisend_simple_delegatecall_PENPIE() public {
        uint256 depositAmount = 1_000 ether;
        uint256 borrowAmount = 500 ether;

        deal(address(PENDLE_LP_STETH2), address(userProxy), depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH2),
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

    function test_multisend_deposit_PENPIE() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(PENDLE_LP_STETH2), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(PENDLE_LP_STETH2),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
        });

        vm.prank(user);
        PENDLE_LP_STETH2.approve(address(userProxy), depositAmount);

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
        deal(address(PENDLE_LP_STETH2), user, amount);
        vm.startPrank(user);
        PENDLE_LP_STETH2.approve(IPendleMarketDepositHelper(pendleDepositHelper).pendleStaking(), amount);
        IPendleMarketDepositHelper(pendleDepositHelper).depositMarketFor(
            address(PENDLE_LP_STETH2),
            address(proxy),
            amount
        );
        vm.stopPrank();
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
                address(userProxy), // user proxy is the position
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
        deal(address(PENDLE_LP_STETH2), user, depositAmount);
        vm.startPrank(user);
        PENDLE_LP_STETH2.approve(IPendleMarketDepositHelper(pendleDepositHelper).pendleStaking(), depositAmount);
        IPendleMarketDepositHelper(pendleDepositHelper).depositMarketFor(
            address(PENDLE_LP_STETH2),
            address(proxy),
            depositAmount
        );
        vm.stopPrank();

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
            auxSwap: auxSwap
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
