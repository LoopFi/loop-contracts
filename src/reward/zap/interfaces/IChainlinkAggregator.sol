// SPDX-License-Identifier: MIT
// Code from https://github.com/smartcontractkit/chainlink/blob/master/evm-contracts/src/v0.6/interfaces/AggregatorV3Interface.sol

pragma solidity ^0.8.19;

import "./AggregatorInterface.sol";
import "./AggregatorV3Interface.sol";

interface IChainlinkAggregator is AggregatorInterface, AggregatorV3Interface {}
