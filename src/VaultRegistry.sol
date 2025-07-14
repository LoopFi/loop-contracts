// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICDPVault} from "./interfaces/ICDPVault.sol";
import {Permission} from "./utils/Permission.sol";
import {Pause, PAUSER_ROLE} from "./utils/Pause.sol";
import {IVaultRegistry} from "./interfaces/IVaultRegistry.sol";
import {AggregatorV3Interface} from "./vendor/AggregatorV3Interface.sol";
import {wdiv} from "./utils/Math.sol";

/// @title VaultRegistry
/// @notice Manages the registration and removal of vaults in the protocol, allowing for user data aggregation by iterating through vaults.
contract VaultRegistry is AccessControl, IVaultRegistry {
    /// @notice Role for managing vaults
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    /// @notice Mapping for quick vault address lookup
    mapping(ICDPVault => bool) private registeredVaults;

    /// @notice Array of registered vaults for iteration
    ICDPVault[] private vaultList;

    /// @notice Mapping of token addresses to their oracle addresses
    mapping(address => AggregatorV3Interface) private tokenOracles;

    /// @notice Event emitted when a new vault is added
    event VaultAdded(ICDPVault indexed vault);

    /// @notice Event emitted when a vault is removed
    event VaultRemoved(ICDPVault indexed vault);

    /// @notice Event emitted when an oracle is set for a token
    event TokenOracleSet(address indexed token, AggregatorV3Interface indexed oracle);

    /// @notice Custom errors for handling various contract operations
    error VaultRegistry__removeVault_vaultNotFound();
    error VaultRegistry__addVault_vaultAlreadyRegistered();
    error VaultRegistry__setTokenOracle_zeroAddress();
    error VaultRegistry__getUserTotalCollateralUSD_oracleNotSet();
    error VaultRegistry__getUserTotalCollateralUSD_invalidOracleData();

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(VAULT_MANAGER_ROLE, msg.sender);
    }

    /// @notice Adds a new vault to the registry
    /// @param vault The address of the vault to add
    function addVault(ICDPVault vault) external override(IVaultRegistry) onlyRole(VAULT_MANAGER_ROLE) {
        if (registeredVaults[vault]) revert VaultRegistry__addVault_vaultAlreadyRegistered();

        registeredVaults[vault] = true;
        vaultList.push(vault);
        emit VaultAdded(vault);
    }

    /// @notice Removes a vault from the registry
    /// @param vault The address of the vault to remove
    function removeVault(ICDPVault vault) external override(IVaultRegistry) onlyRole(VAULT_MANAGER_ROLE) {
        if (!registeredVaults[vault]) revert VaultRegistry__removeVault_vaultNotFound();

        _removeVaultFromList(vault);
        registeredVaults[vault] = false;
        
        emit VaultRemoved(vault);
    }

    /// @notice Returns the list of all registered vaults for iteration
    /// @return The list of registered vault addresses
    function getVaults() external view override(IVaultRegistry) returns (ICDPVault[] memory) {
        return vaultList;
    }

    /// @notice Returns the aggregated position stats for a user across all vaults
    /// @param user The position owner
    function getUserTotalDebt(address user) external view override(IVaultRegistry) returns (uint256 totalNormalDebt) {
        uint256 vaultLen = vaultList.length;
        for (uint256 i = 0; i < vaultLen; ) {
            (, uint256 debt, , , , ) = ICDPVault(vaultList[i]).positions(user);

            totalNormalDebt += debt;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the total collateral value in USD for a user across all vaults
    /// @param user The position owner
    function getUserTotalCollateralUSD(address user) external view override(IVaultRegistry) returns (uint256 totalCollateralUSD) {
        uint256 vaultLen = vaultList.length;
        for (uint256 i = 0; i < vaultLen; ) {
            ICDPVault vault = vaultList[i];
            (uint256 collateral, , , , , ) = vault.positions(user);

            if (collateral > 0) {
                // Get the token address from the vault
                address token = address(vault.token());
                AggregatorV3Interface oracle = tokenOracles[token];
                
                if (address(oracle) == address(0)) {
                    revert VaultRegistry__getUserTotalCollateralUSD_oracleNotSet();
                }

                // Get price from oracle
                (, int256 price, , uint256 updatedAt, ) = oracle.latestRoundData();
                
                // Validate oracle data
                if (price <= 0 || updatedAt == 0) {
                    revert VaultRegistry__getUserTotalCollateralUSD_invalidOracleData();
                }

                // Convert price to 18 decimal format (WAD)
                uint256 decimals = oracle.decimals();
                uint256 priceWad = wdiv(uint256(price), 10**decimals);
                
                // Calculate collateral value: collateral * price / tokenScale
                uint256 tokenScale = vault.tokenScale();
                uint256 collateralValue = (collateral * priceWad) / tokenScale;
                
                totalCollateralUSD += collateralValue;
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Sets the oracle for a specific token
    /// @param token The address of the token
    /// @param oracle The address of the Chainlink-compatible oracle
    function setTokenOracle(address token, AggregatorV3Interface oracle) external override(IVaultRegistry) onlyRole(VAULT_MANAGER_ROLE) {
        if (token == address(0) || address(oracle) == address(0)) {
            revert VaultRegistry__setTokenOracle_zeroAddress();
        }

        tokenOracles[token] = oracle;
        emit TokenOracleSet(token, oracle);
    }

    /// @notice Gets the oracle for a specific token
    /// @param token The address of the token
    /// @return The address of the oracle
    function getTokenOracle(address token) external view override(IVaultRegistry) returns (AggregatorV3Interface) {
        return tokenOracles[token];
    }

    /// @notice Removes a vault from the vaultList array
    /// @param vault The address of the vault to remove
    function _removeVaultFromList(ICDPVault vault) private {
        uint256 vaultLen = vaultList.length;
        for (uint256 i = 0; i < vaultLen; ) {
            if (vaultList[i] == vault) {
                vaultList[i] = vaultList[vaultLen - 1];
                vaultList.pop();
                break;
            }

            unchecked {
                ++i;
            }
        }
    }

    function isVaultRegistered(address vault) external view returns (bool) {
        return registeredVaults[ICDPVault(vault)];
    }
}
