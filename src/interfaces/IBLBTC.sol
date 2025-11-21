// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IBPool Interface
/// @notice Interface for the underlying BPool contract
interface IBPool {
    function getCurrentTokens() external view returns (address[] memory);
    function getBalance(address token) external view returns (uint256);
}

/// @title IBLBTC Interface
/// @notice Interface for BLBTC (Bitlayer BTC) token interactions
/// @dev Based on the ConfigurableRightsPool contract provided
interface IBLBTC is IERC20 {
    /// @notice Join the BLBTC pool by depositing WBTC
    /// @param poolAmountOut Number of pool tokens to receive
    /// @param maxAmountsIn Max amount of asset tokens to spend
    /// @param kol KOL address (can be zero address)
    /// @param user User address receiving the pool tokens
    function joinPool(
        uint256 poolAmountOut,
        uint256[] calldata maxAmountsIn,
        address kol,
        address user
    ) external;

    /// @notice Exit the BLBTC pool and receive underlying tokens
    /// @param poolAmountIn Amount of pool tokens to redeem
    /// @param minAmountsOut Minimum amount of asset tokens to receive
    /// @param user User address receiving the underlying tokens
    function exitPool(
        uint256 poolAmountIn,
        uint256[] calldata minAmountsOut,
        address user
    ) external;

    /// @notice Get the underlying BPool contract
    /// @return Address of the underlying BPool
    function bPool() external view returns (IBPool);
}
