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
import {RewardManagerPenpie} from "src/penpie-rewards/RewardManagerPenpie.sol";
import {console} from "forge-std/console.sol";
interface IPendleDepositHelper {
    function harvest(address _market, uint256 minEth) external;
}
interface IMasterPenpie {
    function updatePool(address _market) external;
    function tokenToPoolInfo(
        address _market
    ) external view returns (address, address, uint256, uint256, uint256, uint256, address, bool);
}
contract RewardManagerPenpieTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    // user
    PRBProxy userProxy;
    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault pendleVault_STETH;
    RewardManagerPenpie rewardManagerPenpie;
    // actions
    PositionActionPenpie positionAction;

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    address pendleOwner = 0x1FcCC097db89A86Bfc474A1028F93958295b1Fb7;
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address pendleDepositHelper = address(0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4);
    address receiptToken = address(0x9dfaacc97aF3b4FcFFf62213F6913E1A848E8881);
    address masterPenpie = address(0x16296859C15289731521F199F0a5f762dF6347d0);

    address pendleToken = 0x808507121B80c02388fAd14726482e061B8da827;
    address pendleStEth = address(PENDLE_LP_STETH2);
    address pendleHolder = 0xa3A7B6F88361F48403514059F1F16C8E78d60EeC;
    address penpieToken = 0x7DEdBce5a2E31E4c75f87FeA60bF796C17718715;
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

        // deploy reward manager
        rewardManagerPenpie = new RewardManagerPenpie(
            address(pendleVault_STETH),
            masterPenpie,
            address(PENDLE_LP_STETH2),
            address(prbProxyRegistry)
        );
        pendleVault_STETH.setParameter("rewardManager", address(rewardManagerPenpie));
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
        vm.label(address(pendleVault_STETH), "pendleVault_STETH");
        vm.label(address(positionAction), "positionAction");
        vm.label(address(penpieToken), "PENPIE");
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

    function test_deposit_withdraw_with_rewards() public {
        // deposit PENDLE_STETH to vault
        uint256 initialDeposit = 100 ether;
        _deposit(userProxy, address(pendleVault_STETH), initialDeposit);

        // Add reward and harvest
        // Mock Penpie Reward
        vm.prank(masterPenpie);
        ERC20(penpieToken).transfer(address(pendleVault_STETH), 1000 ether);
        // Harvest Pendle Reward
        vm.prank(pendleHolder);
        ERC20(pendleToken).transfer(address(pendleStEth), 10000 ether);
        vm.roll(block.number + 500);
        IPendleDepositHelper(0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4).harvest(address(pendleStEth), 0);

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
        assertGt(ERC20(pendleToken).balanceOf(address(user)), 0);
        assertEq(ERC20(penpieToken).balanceOf(address(pendleVault_STETH)), 0, "penpie in vault");
        assertGt(ERC20(penpieToken).balanceOf(address(user)), 0, "penpie in user");
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

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 19356381;
    }
    receive() external payable {}
}
