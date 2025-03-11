// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import "./IntegrationTestBase.sol";
import {wdiv, WAD} from "../../utils/Math.sol";
import {Permission} from "../../utils/Permission.sol";

import {CDPVault} from "../../CDPVault.sol";
import {StakingLPEth} from "../../StakingLPEth.sol";

import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PoolActionParams, PoolActionParams, Protocol} from "../../proxy/PoolAction.sol";

import {PositionAction, CollateralParams, CreditParams, LeverParams} from "../../proxy/PositionAction.sol";

import {PositionAction4626} from "../../proxy/PositionAction4626.sol";

contract PositionAction4626_Lever_Test is IntegrationTestBase {
    using SafeERC20 for ERC20;

    PRBProxy userProxy;
    address user;
    CDPVault vault;
    StakingLPEth stakingLPEth;
    PositionAction4626 positionAction;
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    PoolActionParams emptyPoolActionParams;

    bytes32[] weightedPoolIdArray;

    address constant wstETH_bb_a_WETH_BPTl = 0x41503C9D499ddbd1dCdf818a1b05e9774203Bf46;
    address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant bbaweth = 0xbB6881874825E60e1160416D6C426eae65f2459E;
    bytes32 constant poolId = 0x41503c9d499ddbd1dcdf818a1b05e9774203bf46000000000000000000000594;

    function setUp() public override {
        super.setUp();
        setGlobalDebtCeiling(15_000_000 ether);

        token = ERC20PresetMinterPauser(wstETH);

        stakingLPEth = new StakingLPEth(address(token), "Staking LP ETH", "sLPETH", 0.01 ether);
        stakingLPEth.setCooldownDuration(0);
        vault = createCDPVault(stakingLPEth, 5_000_000 ether, 0, 1.25 ether, 1.0 ether, 1.05 ether);
        createGaugeAndSetGauge(address(vault), address(stakingLPEth));

        user = vm.addr(0x12341234);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));

        positionAction = new PositionAction4626(
            address(flashlender),
            address(swapAction),
            address(poolAction),
            address(vaultRegistry),
            address(mockWETH)
        );

        weightedUnderlierPoolId = _createBalancerPool(address(token), address(underlyingToken)).getPoolId();

        oracle.updateSpot(address(token), 1 ether);
        oracle.updateSpot(address(stakingLPEth), 1 ether);
        weightedPoolIdArray.push(weightedUnderlierPoolId);
    }

    function getForkBlockNumber() internal pure virtual override(IntegrationTestBase) returns (uint256) {
        return 17870449; // Aug-08-2023 01:17:35 PM +UTC
    }
}