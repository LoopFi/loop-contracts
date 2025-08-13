// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ICDPVault} from "./ICDPVault.sol";
import {AggregatorV3Interface} from "../vendor/AggregatorV3Interface.sol";

/// @title IVaultRegistry
/// @notice Interface for the VaultRegistry contract managing vault registrations.
interface IVaultRegistry {
    /// @notice Adds a new vault to the registry.
    /// @param vault The address of the vault to add.
    function addVault(ICDPVault vault) external;

    /// @notice Removes a vault from the registry.
    /// @param vault The address of the vault to remove.
    function removeVault(ICDPVault vault) external;

    /// @notice Returns the list of all registered vaults.
    /// @return An array of registered vault addresses.
    function getVaults() external view returns (ICDPVault[] memory);

    /// @notice Returns the total normal debt of a user.
    /// @param user The position owner
    function getUserTotalDebt(address user) external view returns (uint256 totalNormalDebt);

    /// @notice Returns the total collateral value in USD for a user across all vaults.
    /// @param user The position owner
    function getUserTotalCollateralUSD(address user) external view returns (uint256 totalCollateralUSD);

    /// @notice Sets the oracle for a specific token.
    /// @param token The address of the token.
    /// @param oracle The address of the Chainlink-compatible oracle.
    function setTokenOracle(address token, AggregatorV3Interface oracle) external;

    /// @notice Gets the oracle for a specific token.
    /// @param token The address of the token.
    /// @return The address of the oracle.
    function getTokenOracle(address token) external view returns (AggregatorV3Interface);

    /// @notice Returns if a vault is registered.
    /// @param vault The address of the vault to check.
    function isVaultRegistered(address vault) external view returns (bool);
}
