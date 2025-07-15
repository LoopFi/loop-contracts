// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "../vendor/AggregatorV3Interface.sol";

/// @notice Mock Chainlink oracle that returns a fixed price of 1e18 (1 USD in WAD format)
contract MockChainlinkOracle is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _price;
    uint80 private _roundId;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 price_) {
        _decimals = decimals_;
        _price = price_;
        _roundId = 1;
        _updatedAt = block.timestamp;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock Chainlink Oracle";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 /*_roundId*/
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    // Helper functions for testing
    function setPrice(int256 price_) external {
        _price = price_;
        _roundId++;
        _updatedAt = block.timestamp;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }
} 