// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IChainlinkAdapter {
	function latestAnswer() external view returns (uint256 price);

	function decimals() external view returns (uint8);
}
