pragma solidity ^0.8.17;

import {AggregatorV3Interface} from "src/vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "src/utils/Math.sol";

/// @title CombinedAggregatorV3Oracle
/// @notice This contract combines two Chainlink like oracles to provide a single feed pricing the first feed in the second 
/// (only works when the second feed is the one in which the first is priced) ex. ETH/USD and USD/DAI => ETH/DAI
contract CombinedAggregatorV3Oracle {
    error CombinedAggregatorV3Oracle__invalidAggregatorValue(address aggregator);

    AggregatorV3Interface public immutable aggregator;
    uint256 public immutable aggregatorHeartbeat;
    uint256 public immutable aggregatorScale;

    AggregatorV3Interface public immutable aggregator2;
    uint256 public immutable aggregator2Heartbeat;
    uint256 public immutable aggregator2Scale;

    constructor(address _aggregator, uint256 _aggregatorHeartbeat, address _aggregator2, uint256 _aggregator2Heartbeat) {        
        aggregator = AggregatorV3Interface(_aggregator);
        aggregatorScale = 10 ** uint256(aggregator.decimals());
        aggregatorHeartbeat = _aggregatorHeartbeat;

        aggregator2 = AggregatorV3Interface(_aggregator2);
        aggregator2Scale = 10 ** uint256(aggregator2.decimals());
        aggregator2Heartbeat = _aggregator2Heartbeat;
    }

    function getAggregatorData(AggregatorV3Interface _aggregator, uint256 _aggregatorScale, uint256 _aggregatorHeartbeat) public view returns (uint256, uint256) {
        (, int256 answer, , uint256 updatedAt,) = _aggregator.latestRoundData();
        bool isValid = (answer > 0 && block.timestamp - updatedAt <= _aggregatorHeartbeat);
        if (!isValid) revert CombinedAggregatorV3Oracle__invalidAggregatorValue(address(_aggregator));
        return (wdiv(uint256(answer), _aggregatorScale), updatedAt);
    }

    /// @notice Return the latest price combined from two Chainlink like oracle and the timestamp from the first aggregator
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint256 value, uint256 timestamp) = getAggregatorData(aggregator, aggregatorScale, aggregatorHeartbeat);
        (uint256 value2, ) = getAggregatorData(aggregator2, aggregator2Scale, aggregator2Heartbeat);
        uint256 price = wmul(value, value2);
        return (0, int256(price), 0, timestamp, 0);
    }


    function decimals() public pure returns (uint256) {
        return 18;
    }
}
