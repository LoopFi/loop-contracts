// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPriceProvider} from "../reward/interfaces/IPriceProvider.sol";

contract MockPriceProvider is IPriceProvider {
    // Returns the latest price in ether.
    function getTokenPrice() external pure returns (uint256) {
        return 1e18;
    }

    // Returns the latest price in usd.
    function getTokenPriceUsd() external pure returns (uint256) {
        return 2400 ether;
    }

    function getLpTokenPrice() external pure returns (uint256) {
        return 1e18;
    }

    function getLpTokenPriceUsd() external pure returns (uint256) {
        return 2400 ether;
    }

    function getStablecoinUsd() external pure returns (uint256) {
        return 2400 ether;
    }

    function decimals() external pure returns (uint256) {
        return 18;
    }

    function update() external {}

    function getRewardTokenPrice(address /*rewardToken*/, uint256 /*amount*/) external pure returns (uint256) {
        return 1e18;
    }

    function baseAssetChainlinkAdapter() external view returns (address) {
        return address(0);
    }
} 