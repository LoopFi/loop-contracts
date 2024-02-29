// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ICDM} from "./interfaces/ICDM.sol";
import {IBuffer} from "./interfaces/IBuffer.sol";

import {min} from "./utils/Math.sol";

// Authenticated Roles
bytes32 constant CREDIT_MANAGER_ROLE = keccak256("CREDIT_MANAGER_ROLE");

/// @title Buffer
/// @notice Buffer for credit and debt in the system
contract Buffer is IBuffer, Initializable, AccessControlUpgradeable {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice CDM contract
    ICDM public immutable cdm;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Buffer__withdrawCredit_zeroAddress();

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    // slither-disable-next-line unused-state
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(ICDM cdm_) initializer {
        cdm = cdm_;
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the proxies storage variables
    /// @dev Can only be called once
    /// @param admin Address to whom assign the DEFAULT_ADMIN_ROLE role to
    /// @param manager Address to whom assign the CREDIT_MANAGER_ROLE role to
    function initialize(address admin, address manager) external initializer {
        // init. Access Control
        __AccessControl_init();
        // Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Credit Manager
        _grantRole(CREDIT_MANAGER_ROLE, manager);
    }

    /// @notice Withdraws credit from the buffer to another account
    /// @dev Requires caller to have 'CREDIT_MANAGER_ROLE' role
    /// @param to Account to withdraw credit to
    /// @param amount Amount of credit to withdraw
    function withdrawCredit(address to, uint256 amount) external onlyRole(CREDIT_MANAGER_ROLE) {
        if (to == address(0)) revert Buffer__withdrawCredit_zeroAddress();
        cdm.modifyBalance(address(this), to, amount);
    }
}
