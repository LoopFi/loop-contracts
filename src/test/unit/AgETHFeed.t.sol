pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {Api3Feed, IApi3ReaderProxy} from "src/oracle/api3/Api3Feed.sol";
import {CombinedAggregatorV3Oracle, AggregatorV3Interface} from "src/oracle/CombinedAggregatorV3Oracle.sol";

contract AgETHFeedTest is Test {
    IApi3ReaderProxy api3AgETHrsETHFeed = IApi3ReaderProxy(0xd645b27054434e53798798907Bf41815446Ec2ea);
    AggregatorV3Interface rsETHCl = AggregatorV3Interface(0x03c68933f7a3F76875C0bc670a58e69294cDFD01);
    uint256 api3Heartbeat = 24 hours;
    uint256 clHeartbeat = 24 hours;
    CombinedAggregatorV3Oracle feed;
    Api3Feed api3Feed;
    function setUp() public {
        vm.createSelectFork("mainnet", 21838517);
        api3Feed = new Api3Feed(address(api3AgETHrsETHFeed), api3Heartbeat);
        feed = new CombinedAggregatorV3Oracle(address(api3AgETHrsETHFeed), api3Heartbeat, address(rsETHCl), clHeartbeat, true);
    }

    function test_deploy() public {
        assertNotEq(address(feed), address(0));
    }

    function test_latestRoundData() public {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed
            .latestRoundData();
        (int224 proxyValue, uint256 timestamp) = api3AgETHrsETHFeed.read();
        (, int256 clPrice, , , ) = rsETHCl.latestRoundData();
        assertEq(roundId, 0);
        assertEq(uint(price), (uint224(proxyValue) * uint(clPrice)) / 10 ** 18);
        assertEq(startedAt, 0);
        assertEq(updatedAt, timestamp);
        assertEq(answeredInRound, 0);
        console.log("price", uint(price));
    }
}
