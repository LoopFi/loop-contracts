pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import { PythAggregatorV3, IPyth, PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythAggregatorV3.sol";

contract USD0PlusPlusFeedTest is Test {
    
    PythAggregatorV3 feed;
    address pythPriceFeedsContract = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    bytes32 feedId = 0xf9c96a45784d0ce4390825a43a313149da787e6a6c66076f3a3f83e92501baeb; // USD0++/USD feed id

    function setUp() public {
        vm.createSelectFork("mainnet");
        feed = new PythAggregatorV3(pythPriceFeedsContract,feedId);
    }

    function test_deploy() public {
        assertNotEq(address(feed), address(0));
    }

    function test_latestRoundData() public {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed
            .latestRoundData();
        PythStructs.Price memory pyth = IPyth(pythPriceFeedsContract).getPriceUnsafe(feedId);
        assertEq(roundId,  pyth.publishTime);
        assertEq(price, pyth.price);
        assertEq(startedAt,  pyth.publishTime);
        assertEq(updatedAt, pyth.publishTime);
        assertEq(answeredInRound,  pyth.publishTime);
        console.log("price", uint(price));
    }
}
