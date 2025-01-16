pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import { PythAggregatorV3, IPyth, PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythAggregatorV3.sol";
import {Combined4626AggregatorV3Oracle, IERC4626} from "src/oracle/Combined4626AggregatorV3Oracle.sol";
contract WstUSRFeedTest is Test {
    
    PythAggregatorV3 aggregator;
   
    Combined4626AggregatorV3Oracle feed;

    address pythPriceFeedsContract = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    IERC4626 vault = IERC4626(0x1202F5C7b4B9E47a1A484E8B270be34dbbC75055); // wstUSR/USR vault
    bytes32 feedIdUSRUSD = 0x10b013adec14c0fe839ca0fe54cec9e4d0b6c1585ac6d7e70010dac015e57f9c; // USR/USD

    function setUp() public {
        vm.createSelectFork("mainnet");
       
        aggregator = new PythAggregatorV3(pythPriceFeedsContract,feedIdUSRUSD);
        feed = new Combined4626AggregatorV3Oracle(address(aggregator), 15 days, address(vault));
    }

    function test_deploy() public {
        assertNotEq(address(feed), address(0));
    }

    function test_latestRoundData() public {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed
            .latestRoundData();
        PythStructs.Price memory pyth = IPyth(pythPriceFeedsContract).getPriceUnsafe(feedIdUSRUSD);
        uint256 pythPrice = uint256(int256(pyth.price));
        assertEq(roundId,  0);
        assertEq(uint(price), pythPrice * vault.convertToAssets(1e18) * 10 ** (18 -aggregator.decimals()) / 1e18); 
        assertEq(startedAt,  0);
        assertEq(updatedAt, pyth.publishTime);
        assertEq(answeredInRound,  0);
        console.log("price", uint(price));
    }
}
