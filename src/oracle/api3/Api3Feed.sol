pragma solidity ^0.8.17;

interface IApi3ReaderProxy {
    function read() external view returns (int224, uint32);
}
/// @title API3 Price Feed
/// @notice This contract reads the price from an API3ReaderProxy and validates it, 
/// returning the latest price conforming `latestRoundData` from Chainlink
contract Api3Feed {
    error Api3Chainlink__invalidApi3Value();

    IApi3ReaderProxy public immutable proxy;
    uint256 public immutable api3Heartbeat;
    constructor(address _proxy, uint256 _api3Heartbeat) {
        proxy = IApi3ReaderProxy(_proxy);
        api3Heartbeat = _api3Heartbeat;
    }

    function read() internal view returns (int256, uint256) {
        (int224 value, uint32 timestamp) = proxy.read();
        bool isValid = (value > 0 && block.timestamp - timestamp <= api3Heartbeat);
        if (!isValid) revert Api3Chainlink__invalidApi3Value();
        return (int256(value), uint256(timestamp));
    }

    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (int256 value, uint256 timestamp) = read();
        return (0, value, 0, timestamp, 0);
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
