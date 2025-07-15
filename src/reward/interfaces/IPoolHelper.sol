// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @title IPoolHelper  
/// @notice Generic interface for pool helper contracts
interface IPoolHelper {
    /// @notice Calculate the required amount of the paired token for a given amount of the primary token
    /// @param tokenAmount Amount of the primary token
    /// @return Amount of the paired token needed
    function quoteFromToken(uint256 tokenAmount) external view returns (uint256);

    /// @notice Create LP tokens by providing both tokens
    /// @param wethAmount Amount of WETH to provide
    /// @param tokenAmount Amount of the other token to provide
    /// @return lpAmount Amount of LP tokens received
    function zapTokens(uint256 wethAmount, uint256 tokenAmount) external returns (uint256 lpAmount);

    /// @notice Create LP tokens by providing only WETH
    /// @param wethAmount Amount of WETH to provide
    /// @return lpAmount Amount of LP tokens received
    function zapWETH(uint256 wethAmount) external returns (uint256 lpAmount);

    /// @notice Get the address of the LP token
    /// @return Address of the LP token contract
    function lpTokenAddr() external view returns (address);
}

/// @title IBalancerPoolHelper
/// @notice Interface for Balancer pool helper contracts
interface IBalancerPoolHelper is IPoolHelper {
    // Inherits all methods from IPoolHelper
    // Can add Balancer-specific methods here if needed
} 