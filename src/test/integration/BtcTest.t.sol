// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PRBProxy} from "prb-proxy/PRBProxy.sol";
import {console} from "forge-std/console.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LinearInterestRateModelV3} from "@gearbox-protocol/core-v3/contracts/pool/LinearInterestRateModelV3.sol";
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {IPoolV3} from "../../interfaces/IPoolV3.sol";

import {IntegrationTestBase} from "../integration/IntegrationTestBase.sol";
import {wdiv, wmul} from "../../utils/Math.sol";
import {CDPVault} from "../../CDPVault.sol";
import {ICDPVault} from "../../interfaces/ICDPVault.sol";
import {PoolV3} from "../../PoolV3.sol";
import {Flashlender} from "../../Flashlender.sol";
import {VaultRegistry} from "../../VaultRegistry.sol";
import {PRBProxyRegistry} from "../../prb-proxy/PRBProxyRegistry.sol";
import {IPActionAddRemoveLiqV3} from "pendle/interfaces/IPActionAddRemoveLiqV3.sol";

import {BaseAction} from "../../proxy/BaseAction.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PoolAction, PoolActionParams} from "../../proxy/PoolAction.sol";
import {PositionAction, CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {PositionAction20} from "../../proxy/PositionAction20.sol";

contract MockBTCCollateral is ERC20PresetMinterPauser {
    constructor() ERC20PresetMinterPauser("Mock BTC Collateral", "mBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

contract BtcTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // cdp vaults
    CDPVault vault;

    // actions
    PositionAction20 positionAction;

    MockBTCCollateral collateral;

    ERC20 WBTC = ERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    modifier checkUser(address user) {
        vm.assume(
            user != address(0) &&
            user != address(liquidityPool) &&
            user != address(token) &&
            user != address(vault) &&
            user != address(positionAction) &&
            user != address(swapAction) &&
            user != address(poolAction) &&
            user != address(flashlender) &&
            user != address(vaultRegistry) &&
            user != address(underlyingToken)
        );
        _;
    }

    function setUp() public override {
        super.setUp();

        token = new MockBTCCollateral();

        setOraclePrice(1 * 10 ** 18); // 1 BTC

        vault = createCDPVault(IERC20(address(token)), 100_000 ether, 0, 1.25 ether, 1 ether, 0);
        createGaugeAndSetGauge(address(vault));
    }

    function createCore() internal override {
        LinearInterestRateModelV3 irm = new LinearInterestRateModelV3({
            U_1: 85_00,
            U_2: 95_00,
            R_base: 10_00,
            R_slope1: 20_00,
            R_slope2: 30_00,
            R_slope3: 40_00,
            _isBorrowingMoreU2Forbidden: false
        });
        createAddressProvider();

        liquidityPool = new PoolV3({
            weth_: address(0),
            addressProvider_: address(addressProvider),
            underlyingToken_: address(WBTC),
            interestRateModel_: address(irm),
            totalDebtLimit_: initialGlobalDebtCeiling,
            name_: "Loop Liquidity Pool",
            symbol_: "lpWBTC "
        });
        liquidityPool.setTreasury(mockTreasury);

        underlyingToken = ERC20PresetMinterPauser(address(WBTC));

        flashlender = new Flashlender(IPoolV3(address(liquidityPool)), 0.01 ether);
        liquidityPool.setCreditManagerDebtLimit(address(flashlender), type(uint256).max);
        vaultRegistry = new VaultRegistry();

        prbProxyRegistry = new PRBProxyRegistry();
        swapAction = new SwapAction(balancerVault, univ3Router, IPActionAddRemoveLiqV3(PENDLE_ROUTER), kyberRouter, TRANCHESS_ROUTER);
        poolAction = new PoolAction(BALANCER_VAULT, PENDLE_ROUTER, TRANCHESS_ROUTER);

        // deploy position actions
        positionAction = new PositionAction20(
            address(flashlender),
            address(swapAction),
            address(poolAction),
            address(vaultRegistry),
            address(0)
        );

        vm.label({account: address(liquidityPool), newLabel: "Liquidity Pool"});
        vm.label({account: address(underlyingToken), newLabel: "Underlying Token(WBTC)"});
        vm.label({account: address(flashlender), newLabel: "Flashlender"});
        vm.label({account: address(vaultRegistry), newLabel: "Vault Registry"});
        vm.label({account: address(vault), newLabel: "Vault(BTC)"});
        vm.label({account: address(token), newLabel: "Collateral(BTC)"});
        vm.label({account: address(positionAction), newLabel: "Position Action"});
        vm.label({account: address(swapAction), newLabel: "Swap Action"});
        vm.label({account: address(poolAction), newLabel: "Pool Action"});
    }

    function addLiquidity() internal override {
        uint256 availableLiquidity = 1_000_000 * 10 ** 8;
        deal(address(WBTC), address(this), availableLiquidity);
        
        WBTC.approve(address(liquidityPool), availableLiquidity);
        liquidityPool.deposit(availableLiquidity, address(this));
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 scaledDepositAmount) {
        deal(address(token), user, amount);

        vm.startPrank(user);
        token.approve(address(vault), amount);
        scaledDepositAmount = vault.deposit(user, amount);
        vm.stopPrank();
    }

    function _borrow(address user, uint256 amount) internal returns (uint256 scaledBorrowAmount) {
        vm.prank(user);
        scaledBorrowAmount = vault.borrow(user, user, amount);
    }

    function _repay(address user, uint256 amount) internal returns (uint256 scaledRepayAmount) {
        vm.startPrank(user);
        underlyingToken.approve(address(vault), amount);
        scaledRepayAmount = vault.repay(user, user, amount);
        vm.stopPrank();
    }

    function _deployProxyFor(address user) internal returns (PRBProxy userProxy) {
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));
        vm.prank(address(userProxy));
        token.approve(address(user), type(uint256).max);
        vm.prank(address(userProxy));
        underlyingToken.approve(address(user), type(uint256).max);
    }

    function test_deploy() public {
        assertNotEq(address(token), address(0));
        assertNotEq(address(vault), address(0));

        uint256 collateralDecimals = token.decimals();
        assertEq(collateralDecimals, 8);

        assertEq(address(vault.token()), address(token));
        uint256 collateralScale = 10 ** collateralDecimals;
        assertEq(vault.tokenScale(), collateralScale);

        assertEq(address(vault.pool()), address(liquidityPool));
        uint256 poolUnderlyingScale = 10 ** underlyingToken.decimals();
        assertEq(vault.poolUnderlyingScale(), poolUnderlyingScale);
        uint256 underlyingDecimals = underlyingToken.decimals();
        assertEq(underlyingDecimals, 8);
    }

    function test_deposit(address user) checkUser(user) public {

        uint256 scaledDepositAmount = _deposit(user, 100 * 10 ** 8);

        assertEq(scaledDepositAmount, 100 ether);
        (uint256 posCollateral, , , , , ) = vault.positions(address(user));
        assertEq(posCollateral, scaledDepositAmount);
    }

    function test_withdraw(address user) checkUser(user) public {
        uint256 amount = 100 * 10 ** 8;
        uint256 scaledDepositAmount = _deposit(user, amount);

        vm.startPrank(user);
        uint256 scaledWithdrawAmount = vault.withdraw(user, amount);
        vm.stopPrank();

        assertEq(scaledWithdrawAmount, scaledDepositAmount);
        (uint256 posCollateral, , , , , ) = vault.positions(address(user));
        assertEq(posCollateral, 0);

    }

    function test_action_deposit(address user) checkUser(user) public {
        uint256 depositAmount = 100 * 10 ** 8;

        deal(address(token), user, depositAmount);
        PRBProxy userProxy = _deployProxyFor(user);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(token),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap,
            minAmountOut: 0
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

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(userProxy));

        uint256 expectedCollateral = wdiv(depositAmount, vault.tokenScale());

        assertEq(posCollateral, expectedCollateral);
        assertEq(posDebt, 0);
    }

    function test_action_withdraw(address user) checkUser(user) public {
        uint256 initialDeposit = 100 * 10 ** 8;
        PRBProxy userProxy = _deployProxyFor(user);
        _deposit(address(userProxy), initialDeposit);

        // build withdraw params
        SwapParams memory auxSwap;
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(token),
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
                address(vault),
                collateralParams
            )
        );

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(userProxy));
        assertEq(posCollateral, 0);
        assertEq(posDebt, 0);
    }

    function test_borrow(address user) checkUser(user) public {
        uint256 initialDeposit = 100 * 10 ** 8;
        _deposit(user, initialDeposit);

        uint256 borrowAmount = 50 * 10 ** 8;
        uint256 scaledBorrowAmount = _borrow(user, borrowAmount);

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(user));

        uint256 expectedCollateral = wdiv(initialDeposit, vault.tokenScale());
        assertEq(posCollateral, expectedCollateral);

        uint256 expectedDebt = wdiv(borrowAmount, vault.poolUnderlyingScale());
        assertEq(posDebt, expectedDebt);
        assertEq(posDebt, scaledBorrowAmount);
    }

    function test_repay(address user) checkUser(user) public {
        uint256 initialDeposit = 100 * 10 ** 8;
        uint256 scaledDepositAmount = _deposit(user, initialDeposit);

        uint256 borrowAmount = 50 * 10 ** 8;
        uint256 scaledBorrowAmount = _borrow(user, borrowAmount);

        uint256 repayAmount = 25 * 10 ** 8;
        uint256 scaledRepayAmount = _repay(user, repayAmount);

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(user));
        assertEq(posCollateral, scaledDepositAmount);
        assertEq(posDebt, scaledBorrowAmount - scaledRepayAmount);
    }

    function test_action_borrow(address user) checkUser(user) public {
        uint256 initialDeposit = 100 * 10 ** 8;
        PRBProxy userProxy = _deployProxyFor(user);
        uint256 scaledDepositAmount = _deposit(address(userProxy), initialDeposit);

        // borrow against deposit
        uint256 borrowAmount = 50 * 10 ** 8;
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

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(userProxy));

        assertEq(posCollateral, scaledDepositAmount);
        assertEq(posDebt, wdiv(borrowAmount, vault.poolUnderlyingScale()));
        assertEq(posDebt, 50 ether);
        assertEq(posCollateral, 100 ether);

        assertEq(underlyingToken.balanceOf(address(user)), borrowAmount);
    }

    function test_action_repay(address user) checkUser(user) public {
        uint256 depositAmount = 100 * 10 ** 8;
        uint256 borrowAmount = 50 * 10 ** 8;
        PRBProxy userProxy = _deployProxyFor(user);
        uint256 scaledDepositAmount = _deposit(address(userProxy), depositAmount);
        uint256 scaledBorrowAmount = _borrow(address(userProxy), borrowAmount);
        uint256 scaledRepayAmount = scaledBorrowAmount;

        // build repay params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: address(userProxy),
            auxSwap: auxSwap // no entry swap
        });

        vm.startPrank(user);
        underlyingToken.approve(address(userProxy), borrowAmount);

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

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(userProxy));
        assertEq(posCollateral, scaledDepositAmount);
        assertEq(posDebt, scaledBorrowAmount - scaledRepayAmount);
    }

    function test_repay_withInterest(address user) checkUser(user) public {
        uint256 initialDeposit = 100 * 10 ** 8;
        uint256 scaledDepositAmount = _deposit(user, initialDeposit);

        uint256 borrowAmount = 50 * 10 ** 8;
        uint256 scaledBorrowAmount = _borrow(user, borrowAmount);

        vm.warp(block.timestamp + 365 days);

        uint256 repayAmount = 25 * 10 ** 8;
        uint256 scaledRepayAmount = _repay(user, repayAmount);

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(user));
        assertEq(posCollateral, scaledDepositAmount);
        assertGt(posDebt, scaledBorrowAmount - scaledRepayAmount);
    }

    function test_action_repay_withInterest(address user) checkUser(user) public {
        uint256 depositAmount = 100 * 10 ** 8;
        uint256 borrowAmount = 50 * 10 ** 8;
        PRBProxy userProxy = _deployProxyFor(user);
        uint256 scaledDepositAmount = _deposit(address(userProxy), depositAmount);
        uint256 scaledBorrowAmount = _borrow(address(userProxy), borrowAmount);
        uint256 scaledRepayAmount = scaledBorrowAmount;

        vm.warp(block.timestamp + 365 days);

        // build repay params
        SwapParams memory auxSwap;
        CreditParams memory creditParams = CreditParams({
            amount: borrowAmount,
            creditor: address(userProxy),
            auxSwap: auxSwap // no entry swap
        });

        vm.startPrank(user);
        underlyingToken.approve(address(userProxy), borrowAmount);

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

        (uint256 posCollateral, uint256 posDebt, , , , ) = vault.positions(address(userProxy));
        assertEq(posCollateral, scaledDepositAmount);
        assertGt(posDebt, scaledBorrowAmount - scaledRepayAmount);
    }
}
