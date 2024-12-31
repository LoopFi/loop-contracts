// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "pendle/oracles/PendleLpOracleLib.sol";

import {AggregatorV3Interface} from "../vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "../utils/Math.sol";
import {IOracle, MANAGER_ROLE} from "../interfaces/IOracle.sol";
import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import {PendleLpOracleLib} from "pendle/oracles/PendleLpOracleLib.sol";
import {IPPtOracle} from "pendle/interfaces/IPPtOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// The oracle is upgradable if the current implementation does not return a valid price
/// Oracle implementation for Pendle LP tokens when the asset is an ERC4626 vault
contract PendleLPOracle4626 is IOracle, AccessControlUpgradeable, UUPSUpgradeable {
    using PendleLpOracleLib for IPMarket;
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC4626 Vault address
    IERC4626 public immutable vault;
    /// @notice Pendle Market
    IPMarket public immutable market;
    /// @notice TWAP window in seconds
    uint32 public immutable twapWindow;
    /// @notice Pendle Pt Oracle
    IPPtOracle public immutable ptOracle;

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error PendleLPOracle__authorizeUpgrade_validStatus();
    error PendleLPOracle__validatePtOracle_invalidValue();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor(address ptOracle_, address market_, uint32 twap_, address vault_) initializer {
        market = IPMarket(market_);
        twapWindow = twap_;
        ptOracle = IPPtOracle(ptOracle_);
        vault = IERC4626(vault_);
    }

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
    /// @dev reverts if the caller is not a manager or if the status check succeeds
    function _authorizeUpgrade(address /*implementation*/) internal virtual override onlyRole(MANAGER_ROLE) {
        if (_getStatus()) revert PendleLPOracle__authorizeUpgrade_validStatus();
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the status of the oracle
    /// @param /*token*/ Token address, ignored for this oracle
    /// @dev The status is valid if the price is validated and not stale
    function getStatus(address /*token*/) public view virtual override returns (bool status) {
        return _getStatus();
    }

    /// @notice Returns the latest price for the LP
    /// @param /*token*/ Token address
    /// @return price Asset price [WAD]
    /// @dev reverts if the price is invalid
    function spot(address /* token */) external view virtual override returns (uint256 price) {
        bool isValidPtOracle = _validatePtOracle();
        if (!isValidPtOracle) revert PendleLPOracle__validatePtOracle_invalidValue();
        uint256 lpRate = market.getLpToAssetRate(twapWindow);
        return vault.convertToAssets(lpRate);
    }

    /// @notice Returns the status of the oracle
    /// @return status Whether the oracle is valid
    /// @dev The status is valid if the price is validated and not stale
    function _getStatus() private view returns (bool status) {
        return _validatePtOracle();
    }

    /// @notice Validates the PT oracle
    /// @return isValid Whether the PT oracle is valid for this market and twap window
    function _validatePtOracle() internal view returns (bool isValid) {
        try ptOracle.getOracleState(address(market), twapWindow) returns (
            bool increaseCardinalityRequired,
            uint16,
            bool oldestObservationSatisfied
        ) {
            if (!increaseCardinalityRequired && oldestObservationSatisfied) return true;
        } catch {
            // return default value on failure
        }
    }
}
