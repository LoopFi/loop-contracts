pragma solidity ^0.8.17;

import {AggregatorV3Interface} from "src/vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "src/utils/Math.sol";

interface IApi3ReaderProxy {
    function read() external view returns (int224, uint32);
}

contract Api3FeedChainlink {
    error Api3FeedChainlink__invalidApi3Value();
    error Api3FeedChainlink__invalidChainlinkValue();

    IApi3ReaderProxy public immutable proxy;
    uint256 public immutable api3Heartbeat;
    AggregatorV3Interface public immutable aggregator;
    uint256 public immutable clHeartbeat;
    uint256 public immutable aggregatorScale;

    constructor(address _proxy, uint256 _api3Heartbeat, address _aggregator, uint256 _clHeartbeat) {
        proxy = IApi3ReaderProxy(_proxy);
        api3Heartbeat = _api3Heartbeat;
        aggregator = AggregatorV3Interface(_aggregator);
        aggregatorScale = 10 ** uint256(aggregator.decimals());
        clHeartbeat = _clHeartbeat;
    }

    function read() public view returns (int256, uint256) {
        (int224 value, uint32 timestamp) = proxy.read();
        bool isValid = (value > 0 && block.timestamp - timestamp <= api3Heartbeat);
        if (!isValid) revert Api3FeedChainlink__invalidApi3Value();
        return (int256(value), uint256(timestamp));
    }

    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (int256 value, uint256 timestamp) = read();
        (bool isValid, uint256 price) = _fetchAndValidate();
        if (!isValid) revert Api3FeedChainlink__invalidChainlinkValue();
        price = wmul(uint256(value), price);
        return (0, int256(price), 0, timestamp, 0);
    }

    function _fetchAndValidate() internal view returns (bool isValid, uint256 price) {
        try AggregatorV3Interface(aggregator).latestRoundData() returns (
            uint80,
            int256 answer,
            uint256 /*startedAt*/,
            uint256 updatedAt,
            uint80
        ) {
            isValid = (answer > 0 && block.timestamp - updatedAt <= clHeartbeat);
            return (isValid, wdiv(uint256(answer), aggregatorScale));
        } catch {
            // return the default values (false, 0) on failure
        }
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
