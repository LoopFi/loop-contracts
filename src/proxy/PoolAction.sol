// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferAction, PermitParams} from "./TransferAction.sol";

import {IVault, JoinKind, JoinPoolRequest, ExitKind, ExitPoolRequest} from "../vendor/IBalancerVault.sol";
import {IPActionAddRemoveLiqV3} from "pendle/interfaces/IPActionAddRemoveLiqV3.sol";
import {TokenInput, LimitOrderData} from "pendle/interfaces/IPAllActionTypeV3.sol";
import {ApproxParams} from "pendle/interfaces/IPAllActionTypeV3.sol";
import {IPPrincipalToken} from "pendle/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "pendle/interfaces/IStandardizedYield.sol";
import {IPYieldToken} from "pendle/interfaces/IPYieldToken.sol";
import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import {ISwapRouter} from "src/interfaces/ISwapRouterTranchess.sol";
import {IStableSwap} from "src/interfaces/IStableSwapTranchess.sol";
import {ISpectraRouter} from "src/interfaces/ISpectraRouter.sol";

interface ILiquidityGauge {
    function stableSwap() external view returns (address);
}
/// @notice The protocol to use
enum Protocol {
    BALANCER,
    UNIV3,
    PENDLE,
    TRANCHESS,
    SPECTRA
}

/// @notice The parameters for a join
struct PoolActionParams {
    Protocol protocol;
    uint256 minOut;
    address recipient;
    /// @dev `args` can be used for protocol specific parameters
    bytes args;
}

contract PoolAction is TransferAction {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Balancer v2 Vault
    IVault public immutable balancerVault;
    /// @notice Pendle Router
    IPActionAddRemoveLiqV3 public immutable pendleRouter;
    /// @notice Tranchess Swap Router
    ISwapRouter public immutable tranchessRouter;
    /// @notice Spectra Router
    ISpectraRouter public immutable spectraRouter;
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PoolAction__join_unsupportedProtocol();
    error PoolAction__transferAndJoin_unsupportedProtocol();
    error PoolAction__transferAndJoin_invalidPermitParams();
    error PoolAction__transferAndJoin_invalidAssetOrder();
    error PoolAction__exit_unsupportedProtocol();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address balancerVault_, address _pendleRouter, address _tranchessRouter, address _spectraRouter) {
        balancerVault = IVault(balancerVault_);
        pendleRouter = IPActionAddRemoveLiqV3(_pendleRouter);
        tranchessRouter = ISwapRouter(_tranchessRouter);
        spectraRouter = ISpectraRouter(_spectraRouter);
    }

    /*//////////////////////////////////////////////////////////////
                             JOIN VARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a transfer from an EOA and then join via `PoolActionParams`
    /// @param from The address to transfer from
    /// @param permitParams A list of parameters for the permit transfers,
    /// must be the same length and in the same order as `PoolActionParams` assets
    /// @param poolActionParams The parameters for the join
    function transferAndJoin(
        address from,
        PermitParams[] calldata permitParams,
        PoolActionParams calldata poolActionParams
    ) external {
        if (from != address(this)) {
            if (poolActionParams.protocol == Protocol.BALANCER) {
                (, address[] memory assets, , uint256[] memory maxAmountsIn) = abi.decode(
                    poolActionParams.args,
                    (bytes32, address[], uint256[], uint256[])
                );

                if (assets.length != permitParams.length) {
                    revert PoolAction__transferAndJoin_invalidPermitParams();
                }

                // ensure the assets are in the correct order
                if (assets.length > 1) {
                    for (uint256 i = 0; i < assets.length - 1; i++) {
                        if (assets[i] > assets[i + 1]) {
                            revert PoolAction__transferAndJoin_invalidAssetOrder();
                        }
                    }
                }

                for (uint256 i = 0; i < assets.length; ) {
                    if (maxAmountsIn[i] != 0) {
                        _transferFrom(assets[i], from, address(this), maxAmountsIn[i], permitParams[i]);
                    }

                    unchecked {
                        ++i;
                    }
                }
            } else if (poolActionParams.protocol == Protocol.PENDLE) {
                (, , TokenInput memory input, ) = abi.decode(
                    poolActionParams.args,
                    (address, ApproxParams, TokenInput, LimitOrderData)
                );

                if (input.tokenIn != address(0)) {
                    _transferFrom(input.tokenIn, from, address(this), input.netTokenIn, permitParams[0]);
                }
            } else if (poolActionParams.protocol == Protocol.TRANCHESS) {
                (address lpToken, uint256 baseDelta, uint256 quoteDelta, , ) = abi.decode(
                    poolActionParams.args,
                    (address, uint256, uint256, uint256, uint256)
                );
                IStableSwap stableSwap = IStableSwap(ILiquidityGauge(lpToken).stableSwap());
                address baseAddress = stableSwap.baseAddress();
                address quoteAddress = stableSwap.quoteAddress();

                if (baseDelta != 0) {
                    _transferFrom(baseAddress, from, address(this), baseDelta, permitParams[0]);
                }
                if (quoteDelta != 0) {
                    _transferFrom(quoteAddress, from, address(this), quoteDelta, permitParams[1]);
                }
            } else if (poolActionParams.protocol == Protocol.SPECTRA) {
                (, bytes[] memory inputs, ) = abi.decode(poolActionParams.args, (bytes, bytes[], uint256));
                (address tokenIn, uint256 amountIn) = abi.decode(inputs[0], (address, uint256));
                if (tokenIn != address(0)) {
                    _transferFrom(tokenIn, from, address(this), amountIn, permitParams[0]);
                }
            } else revert PoolAction__transferAndJoin_unsupportedProtocol();
        }

        join(poolActionParams);
    }

    /// @notice Perform a join using the specified protocol
    /// @param poolActionParams The parameters for the join
    function join(PoolActionParams memory poolActionParams) public {
        if (poolActionParams.protocol == Protocol.BALANCER) {
            _balancerJoin(poolActionParams);
        } else if (poolActionParams.protocol == Protocol.PENDLE) {
            _pendleJoin(poolActionParams);
        } else if (poolActionParams.protocol == Protocol.TRANCHESS) {
            _tranchessJoin(poolActionParams);
        } else if (poolActionParams.protocol == Protocol.SPECTRA) {
            _spectraJoin(poolActionParams);
        } else revert PoolAction__join_unsupportedProtocol();
    }

    /// @notice Perform a join using the Balancer protocol
    /// @param poolActionParams The parameters for the join
    /// @dev For more information regarding the Balancer join function check the
    /// documentation in {IBalancerVault}
    function _balancerJoin(PoolActionParams memory poolActionParams) internal {
        (bytes32 poolId, address[] memory assets, uint256[] memory assetsIn, uint256[] memory maxAmountsIn) = abi
            .decode(poolActionParams.args, (bytes32, address[], uint256[], uint256[]));

        for (uint256 i = 0; i < assets.length; ) {
            if (maxAmountsIn[i] != 0) {
                IERC20(assets[i]).forceApprove(address(balancerVault), maxAmountsIn[i]);
            }

            unchecked {
                ++i;
            }
        }

        balancerVault.joinPool(
            poolId,
            address(this),
            poolActionParams.recipient,
            JoinPoolRequest({
                assets: assets,
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, assetsIn, poolActionParams.minOut),
                fromInternalBalance: false
            })
        );
    }

    /// @notice Perform a join using the Pendle protocol
    /// @param poolActionParams The parameters for the join
    /// @dev For more information regarding the Pendle join function check Pendle
    /// documentation
    function _pendleJoin(PoolActionParams memory poolActionParams) internal {
        (
            address market,
            ApproxParams memory guessPtReceivedFromSy,
            TokenInput memory input,
            LimitOrderData memory limit
        ) = abi.decode(poolActionParams.args, (address, ApproxParams, TokenInput, LimitOrderData));

        if (input.tokenIn != address(0)) {
            IERC20(input.tokenIn).forceApprove(address(pendleRouter), input.netTokenIn);
        }

        pendleRouter.addLiquiditySingleToken(
            poolActionParams.recipient,
            market,
            poolActionParams.minOut,
            guessPtReceivedFromSy,
            input,
            limit
        );
    }

    function _tranchessJoin(PoolActionParams memory poolActionParams) internal {
        (address lpToken, uint256 baseDelta, uint256 quoteDelta, uint256 version, uint256 deadline) = abi.decode(
            poolActionParams.args,
            (address, uint256, uint256, uint256, uint256)
        );

        IStableSwap stableSwap = IStableSwap(ILiquidityGauge(lpToken).stableSwap());
        address baseAddress = stableSwap.baseAddress();
        address quoteAddress = stableSwap.quoteAddress();
        if (baseDelta != 0) {
            IERC20(baseAddress).forceApprove(address(tranchessRouter), baseDelta);
        }
        if (quoteDelta != 0) {
            IERC20(quoteAddress).forceApprove(address(tranchessRouter), quoteDelta);
        }

        tranchessRouter.addLiquidity(
            baseAddress,
            quoteAddress,
            baseDelta,
            quoteDelta,
            poolActionParams.minOut,
            version,
            deadline
        );

        if (poolActionParams.recipient != address(this)) {
            IERC20(lpToken).safeTransfer(poolActionParams.recipient, IERC20(lpToken).balanceOf(address(this)));
        }
    }

    function _spectraJoin(PoolActionParams memory poolActionParams) internal {
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) = abi.decode(
            poolActionParams.args,
            (bytes, bytes[], uint256)
        );
        (address tokenIn, uint256 amountIn) = abi.decode(inputs[0], (address, uint256));
        IERC20(tokenIn).forceApprove(address(spectraRouter), amountIn);
        spectraRouter.execute(commands, inputs, deadline);
    }

    /// @notice Helper function to update the join parameters for a levered position
    /// @param poolActionParams The parameters for the join
    /// @param upFrontToken The upfront token for the levered position
    /// @param joinToken The token to join with
    /// @param flashLoanAmount The amount of the flash loan
    /// @param upfrontAmount The amount of the upfront token
    function updateLeverJoin(
        PoolActionParams memory poolActionParams,
        address joinToken,
        address upFrontToken,
        uint256 flashLoanAmount,
        uint256 upfrontAmount
    ) external view returns (PoolActionParams memory outParams) {
        outParams = poolActionParams;

        if (poolActionParams.protocol == Protocol.BALANCER) {
            (bytes32 poolId, address[] memory assets, uint256[] memory assetsIn, uint256[] memory maxAmountsIn) = abi
                .decode(poolActionParams.args, (bytes32, address[], uint256[], uint256[]));

            (address poolToken, ) = balancerVault.getPool(poolId);

            uint256 len = assets.length;
            // the offset is needed because of the BPT token that needs to be skipped from the join
            bool skipIndex = false;
            uint256 joinAmount = flashLoanAmount;
            if (upFrontToken == joinToken) {
                joinAmount += upfrontAmount;
            }

            // update the join parameters with the new amounts
            for (uint256 i = 0; i < len; ) {
                uint256 assetIndex = i - (skipIndex ? 1 : 0);
                if (assets[i] == joinToken) {
                    maxAmountsIn[i] = joinAmount;
                    assetsIn[assetIndex] = joinAmount;
                } else if (assets[i] == upFrontToken && assets[i] != poolToken) {
                    maxAmountsIn[i] = upfrontAmount;
                    assetsIn[assetIndex] = upfrontAmount;
                } else {
                    skipIndex = skipIndex || assets[i] == poolToken;
                    if (assets[i] == poolToken) {
                        maxAmountsIn[i] = 0;
                    }
                }
                unchecked {
                    i++;
                }
            }

            // update the join parameters
            outParams.args = abi.encode(poolId, assets, assetsIn, maxAmountsIn);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             EXIT VARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Exit a protocol specific pool
    /// @param poolActionParams The parameters for the exit
    function exit(PoolActionParams memory poolActionParams) public returns (uint256 retAmount) {
        if (poolActionParams.protocol == Protocol.BALANCER) {
            retAmount = _balancerExit(poolActionParams);
        } else if (poolActionParams.protocol == Protocol.PENDLE) {
            retAmount = _pendleExit(poolActionParams);
        } else if (poolActionParams.protocol == Protocol.TRANCHESS) {
            retAmount = _tranchessExit(poolActionParams);
        } else if (poolActionParams.protocol == Protocol.SPECTRA) {
            retAmount = _spectraExit(poolActionParams);
        } else revert PoolAction__exit_unsupportedProtocol();
    }

    function _balancerExit(PoolActionParams memory poolActionParams) internal returns (uint256 retAmount) {
        (
            bytes32 poolId,
            address bpt,
            uint256 bptAmount,
            uint256 outIndex,
            address[] memory assets,
            uint256[] memory minAmountsOut
        ) = abi.decode(poolActionParams.args, (bytes32, address, uint256, uint256, address[], uint256[]));

        if (bptAmount != 0) IERC20(bpt).forceApprove(address(balancerVault), bptAmount);

        uint256 tmpOutIndex = outIndex;
        for (uint256 i = 0; i <= tmpOutIndex; i++) if (assets[i] == bpt) tmpOutIndex++;
        uint256 balanceBefore = IERC20(assets[tmpOutIndex]).balanceOf(poolActionParams.recipient);

        balancerVault.exitPool(
            poolId,
            address(this),
            payable(poolActionParams.recipient),
            ExitPoolRequest({
                assets: assets,
                minAmountsOut: minAmountsOut,
                userData: abi.encode(ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, bptAmount, outIndex),
                toInternalBalance: false
            })
        );

        return IERC20(assets[tmpOutIndex]).balanceOf(poolActionParams.recipient) - balanceBefore;
    }

    function _pendleExit(PoolActionParams memory poolActionParams) internal returns (uint256 retAmount) {
        (address market, uint256 netLpIn, address tokenOut) = abi.decode(
            poolActionParams.args,
            (address, uint256, address)
        );

        (IStandardizedYield SY, IPPrincipalToken PT, IPYieldToken YT) = IPMarket(market).readTokens();

        if (poolActionParams.recipient != address(this)) {
            IPMarket(market).transferFrom(poolActionParams.recipient, market, netLpIn);
        } else {
            IPMarket(market).transfer(market, netLpIn);
        }

        uint256 netSyToRedeem;

        if (PT.isExpired()) {
            (uint256 netSyRemoved, ) = IPMarket(market).burn(address(SY), address(YT), netLpIn);
            uint256 netSyFromPt = YT.redeemPY(address(SY));
            netSyToRedeem = netSyRemoved + netSyFromPt;
        } else {
            (uint256 netSyRemoved, uint256 netPtRemoved) = IPMarket(market).burn(address(SY), market, netLpIn);
            bytes memory empty;
            (uint256 netSySwappedOut, ) = IPMarket(market).swapExactPtForSy(address(SY), netPtRemoved, empty);
            netSyToRedeem = netSyRemoved + netSySwappedOut;
        }

        return SY.redeem(poolActionParams.recipient, netSyToRedeem, tokenOut, poolActionParams.minOut, true);
    }

    function _tranchessExit(PoolActionParams memory poolActionParams) internal returns (uint256 retAmount) {
        (uint256 version, address lpToken, uint256 lpIn) = abi.decode(
            poolActionParams.args,
            (uint256, address, uint256)
        );

        IStableSwap stableSwap = IStableSwap(ILiquidityGauge(lpToken).stableSwap());
        retAmount = stableSwap.removeQuoteLiquidity(version, lpIn, poolActionParams.minOut);

        if (poolActionParams.recipient != address(this)) {
            IERC20(stableSwap.quoteAddress()).safeTransfer(poolActionParams.recipient, retAmount);
        }
    }

    function _spectraExit(PoolActionParams memory poolActionParams) internal returns (uint256 retAmount) {
        (bytes memory commands, bytes[] memory inputs, address tokenOut, uint256 deadline) = abi.decode(
            poolActionParams.args,
            (bytes, bytes[], address, uint256)
        );

        (address tokenIn, uint256 amountIn) = abi.decode(inputs[0], (address, uint256));
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(address(spectraRouter), amountIn);
        spectraRouter.execute(commands, inputs, deadline);
        retAmount = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
    }
}
