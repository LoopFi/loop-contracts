// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOracle, MANAGER_ROLE} from "../interfaces/IOracle.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title StaticOracle
/// @notice A simple oracle that always returns a static price of 10^18 (WAD) regardless of the token provided.
/// @dev Implements the IOracle interface with fixed values for testing or specific use cases
contract StaticOracle is IOracle, AccessControlUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The static price that will always be returned (10^18)
    uint256 public constant STATIC_PRICE = 1e18;

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error StaticOracle__authorizeUpgrade_notManager();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize method called by the proxy contract
    /// @param admin The address of the admin
    /// @param manager The address of the manager who can authorize upgrades
    function initialize(address admin, address manager) external initializer {
        // init. Access Control
        __AccessControl_init();
        // Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Credit Manager
        _grantRole(MANAGER_ROLE, manager);
    }

    /// @notice Authorizes an upgrade
    /// @param /*implementation*/ The address of the new implementation
    /// @dev Only allows managers to upgrade the contract
    function _authorizeUpgrade(address /*implementation*/) internal override onlyRole(MANAGER_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the static price of 10^18 regardless of token
    /// @param /*token*/ Token address (ignored in this implementation)
    /// @return price Static price of 10^18 (WAD)
    function spot(address /*token*/) external pure override returns (uint256) {
        return STATIC_PRICE;
    }

    /// @notice Returns the status of the oracle (always true)
    /// @param /*token*/ Token address (ignored in this implementation)
    /// @return status Always returns true as this oracle is always valid
    function getStatus(address /*token*/) external pure override returns (bool) {
        return true;
    }
} 