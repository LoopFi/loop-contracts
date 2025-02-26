// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICDPVault} from "../interfaces/ICDPVault.sol";
import {wmul} from "src/utils/Math.sol";
import {PositionAction, LeverParams} from "./PositionAction.sol";
import {PoolActionParams, Protocol} from "./PoolAction.sol";
import {IPendleMarketDepositHelper} from "src/interfaces/IPendleMarketDepositHelper.sol";
import {IPenpieReceiptToken} from "src/interfaces/IPenpieReceiptToken.sol";

/// @title PositionActionPenpie
/// @notice Penpie for Pendle LP implementation of PositionAction base contract
contract PositionActionPenpie is PositionAction {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    IPendleMarketDepositHelper public immutable penpieHelper;

    address public immutable penpieStaking;

    constructor(
        address flashlender_,
        address swapAction_,
        address poolAction_,
        address vaultRegistry_,
        address weth_,
        address penpieHelper_
    ) PositionAction(flashlender_, swapAction_, poolAction_, vaultRegistry_, weth_) {
        penpieHelper = IPendleMarketDepositHelper(penpieHelper_);
        penpieStaking = penpieHelper.pendleStaking();
    }

    /*//////////////////////////////////////////////////////////////
                         VIRTUAL IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit collateral into the vault
    /// @param vault Address of the vault
    /// @param amount Amount of collateral to deposit [CDPVault.tokenScale()]
    /// @param src Pendle LP token address
    /// @return Amount of collateral deposited [wad]
    function _onDeposit(
        address vault,
        address position,
        address src,
        uint256 amount
    ) internal override returns (uint256) {
        address collateralToken = address(ICDPVault(vault).token());

        // if the src is not the collateralToken, we need to deposit the underlying into the Penpie staking contract
        if (src != collateralToken) {
            IERC20(src).forceApprove(address(penpieStaking), amount);
            penpieHelper.depositMarketFor(src, address(this), amount);
        }

        IERC20(collateralToken).forceApprove(vault, amount);
        uint256 depositAmount = ICDPVault(vault).deposit(position, amount);
        uint256 scaledAmount = wmul(depositAmount, ICDPVault(vault).tokenScale());
        return scaledAmount;
    }

    /// @notice Withdraw collateral from the vault
    /// @param vault Address of the vault
    /// @param position Address of the position
    /// @param dst Token the caller expects to receive
    /// @param amount Amount of collateral to withdraw [wad]
    /// @return Amount of collateral withdrawn [CDPVault.tokenScale()]
    function _onWithdraw(
        address vault,
        address position,
        address dst,
        uint256 amount,
        uint256 /*minAmountOut*/
    ) internal override returns (uint256) {
        uint256 scaledCollateralWithdrawn = ICDPVault(vault).withdraw(address(position), amount);
        uint256 collateralWithdrawn = wmul(scaledCollateralWithdrawn, ICDPVault(vault).tokenScale());
        address collateralToken = address(ICDPVault(vault).token());

        if (dst != collateralToken && dst != address(0)) {
            penpieHelper.withdrawMarket(dst, collateralWithdrawn);
        }
        return collateralWithdrawn;
    }

    /// @notice Hook to increase lever by depositing collateral into the CDPVault
    /// @param leverParams LeverParams struct
    /// @param /*upFrontToken*/ the address of the token passed up front
    /// @param /*upFrontAmount*/ the amount of tokens passed up front [CDPVault.tokenScale()]
    /// @param /*swapAmountOut*/ the amount of tokens received from the stablecoin flash loan swap [CDPVault.tokenScale()]
    /// @return addCollateralAmount Amount of collateral added to CDPVault position [CDPVault.tokenScale()]
    function _onIncreaseLever(
        LeverParams memory leverParams,
        address /*upFrontToken*/,
        uint256 /*upFrontAmount*/,
        uint256 /*swapAmountOut*/
    ) internal override returns (uint256 addCollateralAmount) {
        if (leverParams.auxAction.args.length != 0) {
            _delegateCall(address(poolAction), abi.encodeWithSelector(poolAction.join.selector, leverParams.auxAction));
        }
        address underlying = IPenpieReceiptToken(address(ICDPVault(leverParams.vault).token())).underlying();
        
        addCollateralAmount = IERC20(underlying).balanceOf(address(this));
        IERC20(underlying).forceApprove(address(penpieStaking), addCollateralAmount);
        penpieHelper.depositMarketFor(underlying, address(this), addCollateralAmount);

        addCollateralAmount = ICDPVault(leverParams.vault).token().balanceOf(address(this));
        ICDPVault(leverParams.vault).token().forceApprove(leverParams.vault, addCollateralAmount);

        // deposit into the CDP Vault
        return addCollateralAmount;
    }

    /// @notice Hook to decrease lever by withdrawing collateral from the CDPVault
    /// @param leverParams LeverParams struct
    /// @param subCollateral Amount of collateral to subtract in CDPVault decimals [wad]
    /// @return tokenOut Amount of underlying token of Pendle SY [underlying scale]
    function _onDecreaseLever(
        LeverParams memory leverParams,
        uint256 subCollateral
    ) internal override returns (uint256 tokenOut) {
        _onWithdraw(leverParams.vault, leverParams.position, address(0), subCollateral, 0);
        (address pendleToken, , ) = abi.decode(leverParams.auxAction.args, (address, uint256, address));
        penpieHelper.withdrawMarket(pendleToken, subCollateral);
        if (leverParams.auxAction.args.length != 0) {
            bytes memory exitData = _delegateCall(
                address(poolAction),
                abi.encodeWithSelector(poolAction.exit.selector, leverParams.auxAction)
            );

            tokenOut = abi.decode(exitData, (uint256));
        }
    }
}
