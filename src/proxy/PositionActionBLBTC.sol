// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICDPVault} from "../interfaces/ICDPVault.sol";
import {IBLBTC, IBPool} from "../interfaces/IBLBTC.sol";
import {wmul, wdiv, toInt256, min} from "src/utils/Math.sol";
import {PositionAction, LeverParams} from "./PositionAction.sol";

/// @title PositionActionBLBTC
/// @notice BLBTC (Bitlayer BTC) implementation of PositionAction base contract
/// @dev Handles conversion between WBTC and BLBTC tokens for leveraged positions
contract PositionActionBLBTC is PositionAction {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice WBTC token address (underlying asset)
    address public immutable WBTC;

    constructor(
        address flashlender_,
        address swapAction_,
        address poolAction_,
        address vaultRegistry_,
        address weth_,
        address wbtc_
    ) PositionAction(flashlender_, swapAction_, poolAction_, vaultRegistry_, weth_) {
        WBTC = wbtc_;
    }

    /*//////////////////////////////////////////////////////////////
                         VIRTUAL IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit collateral into the vault
    /// @param vault Address of the vault
    /// @param position Address of the position
    /// @param src Source token address (WBTC or BLBTC)
    /// @param amount Amount of collateral to deposit [CDPVault.tokenScale()]
    /// @return Amount of collateral deposited [CDPVault.tokenScale()]
    function _onDeposit(
        address vault,
        address position,
        address src,
        uint256 amount
    ) internal override returns (uint256) {
        address collateralToken = address(ICDPVault(vault).token());
        uint256 collateralAmount = amount;

        // If the src is WBTC, we need to join the BLBTC pool to get BLBTC tokens
        if (src == WBTC && src != collateralToken) {
            collateralAmount = _joinBLBTCPool(collateralToken, amount);
        }

        IERC20(collateralToken).forceApprove(vault, collateralAmount);
        uint256 scaledAmount = ICDPVault(vault).deposit(position, collateralAmount);
        uint256 depositAmount = wmul(scaledAmount, ICDPVault(vault).tokenScale());
        return depositAmount;
    }

    /// @notice Withdraw collateral from the vault
    /// @param vault Address of the vault
    /// @param position Address of the position
    /// @param dst Token the caller expects to receive (WBTC or BLBTC)
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

        // If the destination is WBTC and we have BLBTC, exit the pool to get WBTC
        if (dst == WBTC && dst != collateralToken) {
            uint256 wbtcBalanceBefore = IERC20(WBTC).balanceOf(address(this));
            _exitBLBTCPool(collateralToken, collateralWithdrawn);
            uint256 wbtcBalanceAfter = IERC20(WBTC).balanceOf(address(this));
            return wbtcBalanceAfter - wbtcBalanceBefore; // Return actual WBTC received
        }

        return collateralWithdrawn;
    }

    /// @notice Hook to increase lever by depositing collateral into the CDPVault
    /// @param leverParams LeverParams struct
    /// @param upFrontToken The address of the token passed up front (should be WBTC)
    /// @param upFrontAmount The amount of tokens passed up front [CDPVault.tokenScale()]
    /// @param swapAmountOut The amount of WBTC received from the stablecoin flash loan swap [CDPVault.tokenScale()]
    /// @return addCollateralAmount Amount of collateral added to CDPVault position [CDPVault.tokenScale()]
    function _onIncreaseLever(
        LeverParams memory leverParams,
        address upFrontToken,
        uint256 upFrontAmount,
        uint256 swapAmountOut
    ) internal override returns (uint256 addCollateralAmount) {
        address collateralToken = address(ICDPVault(leverParams.vault).token());
        
        // Total WBTC available = upfront amount + flash loan swap output
        uint256 totalWBTC = upFrontAmount + swapAmountOut;
        
        // Join the BLBTC pool with WBTC to get BLBTC tokens
        _joinBLBTCPool(collateralToken, totalWBTC);
        
        // Get the BLBTC balance after joining the pool
        addCollateralAmount = IERC20(collateralToken).balanceOf(address(this));
        
        // Approve the vault to spend the BLBTC tokens
        IERC20(collateralToken).forceApprove(leverParams.vault, addCollateralAmount);

        return addCollateralAmount;
    }

    /// @notice Hook to decrease lever by withdrawing collateral from the CDPVault
    /// @param leverParams LeverParams struct
    /// @param subCollateral Amount of collateral to subtract in CDPVault decimals [wad]
    /// @return tokenOut Amount of BLBTC withdrawn from the vault [BLBTC scale]
    function _onDecreaseLever(
        LeverParams memory leverParams,
        uint256 subCollateral
    ) internal override returns (uint256 tokenOut) {
        address collateralToken = address(ICDPVault(leverParams.vault).token());
        
        // Withdraw BLBTC from the vault
        _onWithdraw(leverParams.vault, leverParams.position, collateralToken, subCollateral, 0);
        
        // Get the BLBTC balance after withdrawal
        uint256 blbtcBalance = IERC20(collateralToken).balanceOf(address(this));
        
        // Return the amount of BLBTC withdrawn (the base PositionAction will handle the swap)
        return blbtcBalance;
    }

    /*//////////////////////////////////////////////////////////////
                          FLASHLOAN CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Override the flash loan callback to handle WBTC to BLBTC conversion without swapping
    /// @dev This bypasses the swap action entirely since we don't need to swap WBTC to anything else
    function onFlashLoan(
        address /*initiator*/,
        address /*token*/,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != address(flashlender)) revert PositionAction__onFlashLoan__invalidSender();

        (LeverParams memory leverParams, address upFrontToken, uint256 upFrontAmount) = abi.decode(
            data,
            (LeverParams, address, uint256)
        );

        // For BLBTC, we don't need to swap - we convert WBTC directly to BLBTC
        // The flash loan gives us WBTC, and we combine it with any upfront WBTC
        uint256 totalWBTC = amount + upFrontAmount;
        
        // Convert WBTC to BLBTC and get the amount of collateral
        uint256 collateral = _joinBLBTCPool(address(ICDPVault(leverParams.vault).token()), totalWBTC);

        // Approve the vault to spend the BLBTC tokens
        IERC20(address(ICDPVault(leverParams.vault).token())).forceApprove(leverParams.vault, collateral);

        // derive the amount of normal debt from the flash loan amount
        uint256 addDebt = amount + fee;

        // Convert to WAD precision (18 decimals) for modifyCollateralAndDebt
        // collateral is in BLBTC units (18 decimals), so it's already in WAD precision
        uint256 scaledCollateral = collateral;
        // addDebt is in WBTC units, and WBTC on Bitlayer has 18 decimals (same as poolUnderlyingScale)
        // So we can use the standard scaling logic from the base PositionAction
        uint256 scaledDebt = wdiv(addDebt, ICDPVault(leverParams.vault).poolUnderlyingScale());
        
        // add collateral and debt
        ICDPVault(leverParams.vault).modifyCollateralAndDebt(
            leverParams.position,
            address(this),
            address(this),
            toInt256(scaledCollateral),
            toInt256(scaledDebt)
        );

        IERC20(WBTC).forceApprove(address(flashlender), addDebt);

        return CALLBACK_SUCCESS;
    }

    /// @notice Override the credit flash loan callback to handle BLBTC to WBTC conversion without swapping
    /// @dev This bypasses the swap action entirely since we handle BLBTC → WBTC conversion directly
    function onCreditFlashLoan(
        address /*initiator*/,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != address(flashlender)) revert PositionAction__onCreditFlashLoan__invalidSender();

        (LeverParams memory leverParams, uint256 subCollateral, address residualRecipient) = abi.decode(
            data,
            (LeverParams, uint256, address)
        );

        _handleDecreaseLeverFlow(leverParams, subCollateral, residualRecipient, fee);
        return CALLBACK_SUCCESS_CREDIT;
    }

    /// @notice Internal function to handle the decrease lever flow
    function _handleDecreaseLeverFlow(
        LeverParams memory leverParams,
        uint256 subCollateral,
        address residualRecipient,
        uint256 fee
    ) internal {
        // Calculate repayment amount
        uint256 totalDebt = ICDPVault(leverParams.vault).virtualDebt(leverParams.position);
        uint256 subDebt = min(totalDebt + fee, leverParams.primarySwap.limit);

        // Reduce debt
        IERC20(WBTC).forceApprove(address(leverParams.vault), subDebt + fee);
        uint256 scaledDebt = wdiv(subDebt - fee, ICDPVault(leverParams.vault).poolUnderlyingScale());
        ICDPVault(leverParams.vault).modifyCollateralAndDebt(
            leverParams.position,
            address(this),
            address(this),
            0,
            -toInt256(scaledDebt)
        );

        // Withdraw and convert BLBTC to WBTC
        uint256 withdrawnCollateral = _onDecreaseLever(leverParams, subCollateral);
        _exitBLBTCPool(address(ICDPVault(leverParams.vault).token()), withdrawnCollateral);
        
        // Handle residual and repayment
        uint256 repayAmount = subDebt + fee;
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(this));
        if (wbtcBalance > repayAmount) {
            IERC20(WBTC).safeTransfer(residualRecipient, wbtcBalance - repayAmount);
        }
        IERC20(WBTC).forceApprove(address(flashlender), repayAmount);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Join the BLBTC pool by depositing WBTC
    /// @param blbtcToken Address of the BLBTC token contract
    /// @param wbtcAmount Amount of WBTC to deposit
    /// @return blbtcReceived Amount of BLBTC tokens received
    function _joinBLBTCPool(address blbtcToken, uint256 wbtcAmount) internal returns (uint256 blbtcReceived) {
        IBLBTC blbtc = IBLBTC(blbtcToken);
        IBPool bPool = blbtc.bPool();
        
        // Approve WBTC spending for the BLBTC contract
        IERC20(WBTC).forceApprove(blbtcToken, wbtcAmount);
        
        // Get current tokens in the pool to construct maxAmountsIn array
        address[] memory poolTokens = bPool.getCurrentTokens();
        uint256[] memory maxAmountsIn = new uint256[](poolTokens.length);
        
        // Find WBTC in the pool tokens and set the max amount
        for (uint256 i = 0; i < poolTokens.length; i++) {
            if (poolTokens[i] == WBTC) {
                maxAmountsIn[i] = wbtcAmount;
            } else {
                maxAmountsIn[i] = 0; // No other tokens to deposit
            }
        }
        
        // Calculate expected pool tokens out based on current pool state
        // WBTC has 8 decimals, BLBTC has 18 decimals
        // We need to calculate the proportional amount of pool tokens to mint
        uint256 wbtcBalance = bPool.getBalance(WBTC);
        uint256 totalSupply = IERC20(blbtcToken).totalSupply();
        
        // Calculate pool tokens proportionally: (wbtcAmount / wbtcBalance) * totalSupply
        // But we need to be careful with precision and decimal differences
        uint256 poolAmountOut = (wbtcAmount * totalSupply) / wbtcBalance;
        
        // Get initial BLBTC balance
        uint256 initialBalance = IERC20(blbtcToken).balanceOf(address(this));
        
        // Join the pool
        blbtc.joinPool(poolAmountOut, maxAmountsIn, address(0), address(this));
        
        // Calculate BLBTC tokens received
        blbtcReceived = IERC20(blbtcToken).balanceOf(address(this)) - initialBalance;
    }

    /// @notice Exit the BLBTC pool to receive WBTC
    /// @param blbtcToken Address of the BLBTC token contract
    /// @param blbtcAmount Amount of BLBTC tokens to redeem
    function _exitBLBTCPool(address blbtcToken, uint256 blbtcAmount) internal {
        IBLBTC blbtc = IBLBTC(blbtcToken);
        IBPool bPool = blbtc.bPool();
        
        // Get current tokens in the pool to construct minAmountsOut array
        address[] memory poolTokens = bPool.getCurrentTokens();
        uint256[] memory minAmountsOut = new uint256[](poolTokens.length);
        
        // Set minimum amounts out (we'll accept any amount for simplicity)
        for (uint256 i = 0; i < poolTokens.length; i++) {
            minAmountsOut[i] = 0; // Accept any amount out
        }
        
        // Exit the pool
        blbtc.exitPool(blbtcAmount, minAmountsOut, address(this));
    }
}
