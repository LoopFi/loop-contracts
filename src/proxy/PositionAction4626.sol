// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICDPVault} from "../interfaces/ICDPVault.sol";
import {wmul} from "../utils/Math.sol";

import {PositionAction, LeverParams, PoolActionParams} from "./PositionAction.sol";

/// @title PositionAction4626
/// @notice ERC4626 implementation of PositionAction
contract PositionAction4626 is PositionAction {
    using SafeERC20 for IERC20;

    constructor(
        address flashlender_,
        address swapActions_,
        address poolAction_,
        address vaultRegistry_,
        address weth_,
        address multiFeeDistribution_,
        address loopToken_,
        address poolHelper_
    ) PositionAction(flashlender_, swapActions_, poolAction_, vaultRegistry_, weth_, multiFeeDistribution_, loopToken_, poolHelper_) {}

    // Cache vault instance and scale
    function _getVaultData(address vault) private view returns (ICDPVault v, address token, uint256 scale) {
        v = ICDPVault(vault);
        token = address(v.token());
        scale = v.tokenScale();
    }

    function _onDeposit(address vault, address position, address src, uint256 amount) internal override returns (uint256) {
        (ICDPVault v, address collateral, uint256 scale) = _getVaultData(vault);

        if (src != collateral) {
            IERC4626 vault4626 = IERC4626(collateral);
            address underlying = vault4626.asset();
            IERC20(underlying).forceApprove(collateral, amount);
            amount = vault4626.deposit(amount, address(this));
        }

        IERC20(collateral).forceApprove(vault, amount);
        return wmul(v.deposit(position, amount), scale);
    }

    function _onWithdraw(
        address vault,
        address position,
        address dst,
        uint256 amount,
        uint256 /*minAmountOut*/
    ) internal override returns (uint256) {
        (ICDPVault v, address collateral, uint256 scale) = _getVaultData(vault);
        uint256 withdrawn = wmul(v.withdraw(position, amount), scale);

        if (dst == collateral) return withdrawn;
        return IERC4626(collateral).redeem(withdrawn, address(this), address(this));
        }

    function _onIncreaseLever(
        LeverParams memory leverParams,
        address upFrontToken,
        uint256 upFrontAmount,
        uint256 swapAmountOut
    ) internal override returns (uint256) {
        uint256 upFrontCollateral;
        uint256 addCollateralAmount = swapAmountOut;
        
        if (leverParams.collateralToken == upFrontToken && leverParams.auxSwap.assetIn == address(0)) {
            upFrontCollateral = upFrontAmount;
        } else {
            addCollateralAmount += upFrontAmount;
        }

        IERC4626 vault4626 = IERC4626(leverParams.collateralToken);
        address underlyingToken = vault4626.asset();
        
        if (leverParams.auxAction.args.length != 0) {
            address joinToken = swapAction.getSwapToken(leverParams.primarySwap);
            address joinUpfrontToken = leverParams.auxSwap.assetIn != address(0) 
                ? swapAction.getSwapToken(leverParams.auxSwap) 
                : upFrontToken;

            PoolActionParams memory poolActionParams = poolAction.updateLeverJoin(
                leverParams.auxAction,
                joinToken,
                joinUpfrontToken,
                swapAmountOut,
                upFrontAmount
            );

            _delegateCall(address(poolAction), abi.encodeWithSelector(poolAction.join.selector, poolActionParams));
            addCollateralAmount = IERC20(underlyingToken).balanceOf(address(this));
        }

        IERC20(underlyingToken).forceApprove(leverParams.collateralToken, addCollateralAmount);
        addCollateralAmount = vault4626.deposit(addCollateralAmount, address(this)) + upFrontCollateral;

        IERC20(leverParams.collateralToken).forceApprove(leverParams.vault, addCollateralAmount);
        return addCollateralAmount;
    }

    function _onDecreaseLever(
        LeverParams memory leverParams,
        uint256 subCollateral
    ) internal override returns (uint256 tokenOut) {
        (ICDPVault v, , uint256 scale) = _getVaultData(leverParams.vault);
        uint256 withdrawn = wmul(v.withdraw(leverParams.position, subCollateral), scale);

        tokenOut = IERC4626(leverParams.collateralToken).redeem(withdrawn, address(this), address(this));

        if (leverParams.auxAction.args.length != 0) {
            bytes memory exitData = _delegateCall(
                address(poolAction),
                abi.encodeWithSelector(poolAction.exit.selector, leverParams.auxAction)
            );
            tokenOut = abi.decode(exitData, (uint256));
        }
    }
}
