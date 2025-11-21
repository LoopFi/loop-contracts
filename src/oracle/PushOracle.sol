// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {wdiv, wmul, WAD} from "../utils/Math.sol";
import {IOracle, MANAGER_ROLE} from "../interfaces/IOracle.sol";

/// @title PushOracle
/// @notice Oracle that accepts price updates from authorized EOAs with TWAP functionality
/// @dev Implements time-weighted average pricing and staleness checks
contract PushOracle is IOracle, AccessControlUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for price updaters
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE");

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Simple TWAP data structure
    struct TWAPData {
        uint256 price;           // Current TWAP price in WAD format
        uint256 lastTimestamp;   // Timestamp of last update
        uint256 spotPrice;       // Latest spot price (for non-TWAP tokens)
    }

    /// @notice Oracle configuration for each token
    struct OracleConfig {
        uint256 stalePeriod;     // Maximum age before price becomes stale
        uint256 twapWindow;      // Time window for TWAP smoothing (half-life)
        bool twapEnabled;        // Whether TWAP is enabled for this token
    }

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping from token address to oracle configuration
    mapping(address => OracleConfig) public oracleConfigs;

    /// @notice Mapping from token address to TWAP data
    mapping(address => TWAPData) public twapData;

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a price is updated
    event PriceUpdated(address indexed token, uint256 price, address indexed updater, uint256 timestamp);

    /// @notice Emitted when oracle configuration is updated
    event OracleConfigUpdated(address indexed token, uint256 stalePeriod, uint256 twapWindow, bool twapEnabled);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PushOracle__spot_invalidValue();
    error PushOracle__spot_stalePrice();
    error PushOracle__updatePrice_invalidPrice();
    error PushOracle__updatePrice_tokenNotConfigured();
    error PushOracle__setOracleConfig_invalidWindow();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorizes an upgrade
    /// @param /*implementation*/ The address of the new implementation
    /// @dev reverts if the caller is not a manager
    function _authorizeUpgrade(address /*implementation*/) internal virtual override onlyRole(MANAGER_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                          CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set oracle configuration for tokens
    /// @param tokens Array of token addresses
    /// @param configs Array of oracle configurations
    function setOracleConfigs(
        address[] calldata tokens,
        OracleConfig[] calldata configs
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokens.length == configs.length, "Array length mismatch");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            if (configs[i].twapEnabled && configs[i].twapWindow == 0) {
                revert PushOracle__setOracleConfig_invalidWindow();
            }
            
            oracleConfigs[tokens[i]] = configs[i];
            
            emit OracleConfigUpdated(
                tokens[i],
                configs[i].stalePeriod,
                configs[i].twapWindow,
                configs[i].twapEnabled
            );
        }
    }

    /// @notice Grant price updater role to an address
    /// @param updater Address to grant the role to
    function grantPriceUpdaterRole(address updater) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PRICE_UPDATER_ROLE, updater);
    }

    /// @notice Revoke price updater role from an address
    /// @param updater Address to revoke the role from
    function revokePriceUpdaterRole(address updater) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(PRICE_UPDATER_ROLE, updater);
    }

    /*//////////////////////////////////////////////////////////////
                           PRICE UPDATES
    //////////////////////////////////////////////////////////////*/

    /// @notice Update price for a token
    /// @param token Token address
    /// @param price New price in WAD format
    function updatePrice(address token, uint256 price) external onlyRole(PRICE_UPDATER_ROLE) {
        _updatePrice(token, price);
    }

    /// @notice Batch update prices for multiple tokens
    /// @param tokens Array of token addresses
    /// @param prices Array of prices in WAD format
    function updatePrices(
        address[] calldata tokens,
        uint256[] calldata prices
    ) external onlyRole(PRICE_UPDATER_ROLE) {
        require(tokens.length == prices.length, "Array length mismatch");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            _updatePrice(tokens[i], prices[i]);
        }
    }

    /// @notice Internal function to update price for a token
    /// @param token Token address
    /// @param price New price in WAD format
    function _updatePrice(address token, uint256 price) internal {
        if (price == 0) revert PushOracle__updatePrice_invalidPrice();
        
        OracleConfig memory config = oracleConfigs[token];
        if (config.stalePeriod == 0) revert PushOracle__updatePrice_tokenNotConfigured();

        uint256 timestamp = block.timestamp;
        TWAPData storage data = twapData[token];
        
        if (config.twapEnabled) {
            // Update TWAP using exponential moving average
            data.price = _calculateNewTWAP(data.price, data.lastTimestamp, price, timestamp, config.twapWindow);
        } else {
            // Simple spot price update
            data.price = price;
        }
        
        data.spotPrice = price;
        data.lastTimestamp = timestamp;

        emit PriceUpdated(token, price, msg.sender, timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the status of the oracle
    /// @param token Token address
    /// @dev The status is valid if the price exists and is not stale
    function getStatus(address token) public view virtual override returns (bool status) {
        OracleConfig memory config = oracleConfigs[token];
        TWAPData memory data = twapData[token];
        
        if (config.stalePeriod == 0 || data.lastTimestamp == 0) return false;
        return (block.timestamp - data.lastTimestamp <= config.stalePeriod);
    }

    /// @notice Returns the latest price for the asset
    /// @param token Token address
    /// @return price Asset price [WAD]
    /// @dev reverts if the price is invalid or stale
    function spot(address token) external view virtual override returns (uint256 price) {
        OracleConfig memory config = oracleConfigs[token];
        if (config.stalePeriod == 0) revert PushOracle__spot_invalidValue();

        TWAPData memory data = twapData[token];
        if (data.lastTimestamp == 0) revert PushOracle__spot_invalidValue();
        
        // Check staleness
        if (block.timestamp - data.lastTimestamp > config.stalePeriod) {
            revert PushOracle__spot_stalePrice();
        }

        price = data.price;
        if (price == 0) revert PushOracle__spot_invalidValue();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate new TWAP using exponential moving average
    /// @param currentTWAP Current TWAP value
    /// @param lastTimestamp Timestamp of last update
    /// @param newPrice New price to incorporate
    /// @param newTimestamp Timestamp of new price
    /// @param twapWindow Time window for TWAP smoothing (half-life in seconds)
    /// @return newTWAP Updated TWAP value
    function _calculateNewTWAP(
        uint256 currentTWAP,
        uint256 lastTimestamp,
        uint256 newPrice,
        uint256 newTimestamp,
        uint256 twapWindow
    ) private pure returns (uint256 newTWAP) {
        // If this is the first price update, return the new price
        if (lastTimestamp == 0 || currentTWAP == 0) {
            return newPrice;
        }

        // Calculate time elapsed since last update
        uint256 timeElapsed = newTimestamp - lastTimestamp;
        
        // If no time has passed, return current TWAP
        if (timeElapsed == 0) {
            return currentTWAP;
        }

        // Calculate the weight for the new price using exponential decay
        // We cap the maximum weight to maintain some memory of old prices
        // This provides better attack resistance even for long time gaps
        
        uint256 maxWeight = 800000000000000000; // 80% (0.8 WAD) - configurable max weight
        uint256 weight;
        
        if (timeElapsed >= twapWindow) {
            // Even for very long gaps, cap at maxWeight to preserve some old TWAP
            weight = maxWeight;
        } else {
            // Linear interpolation: weight = timeElapsed / twapWindow
            weight = wdiv(timeElapsed, twapWindow);
            // Also cap during normal operation to ensure we never exceed maxWeight
            if (weight > maxWeight) {
                weight = maxWeight;
            }
        }

        // Calculate new TWAP: newTWAP = currentTWAP * (1 - weight) + newPrice * weight
        // Since we cap weight at maxWeight (80%), we always blend old and new prices
        uint256 oldWeight = WAD - weight;
        newTWAP = wmul(currentTWAP, oldWeight) + wmul(newPrice, weight);
        
        return newTWAP;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the latest price data for a token
    /// @param token Token address
    /// @return spotPrice Latest spot price
    /// @return twapPrice Current TWAP price (same as spot if TWAP disabled)
    /// @return timestamp Latest update timestamp
    function getLatestPriceData(address token) external view returns (uint256 spotPrice, uint256 twapPrice, uint256 timestamp) {
        TWAPData memory data = twapData[token];
        return (data.spotPrice, data.price, data.lastTimestamp);
    }

    /// @notice Get current TWAP for a token (view function)
    /// @param token Token address
    /// @return twapPrice Current TWAP price
    function getTWAP(address token) external view returns (uint256 twapPrice) {
        OracleConfig memory config = oracleConfigs[token];
        if (!config.twapEnabled) revert PushOracle__spot_invalidValue();
        
        return twapData[token].price;
    }

    /// @notice Get the spot price (latest price update) for a token
    /// @param token Token address
    /// @return spotPrice Latest spot price
    function getSpotPrice(address token) external view returns (uint256 spotPrice) {
        return twapData[token].spotPrice;
    }
}
