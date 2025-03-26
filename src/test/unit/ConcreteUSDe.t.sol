pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {AggregatorV3Interface} from "src/oracle/CombinedAggregatorV3Oracle.sol";
import {PendleLPOracle, IPMarket, IPPYLpOracle} from "src/oracle/PendleLPOracle.sol";
import {PendleLpOracleLib} from "pendle/oracles/PtYtLpOracle/PendleLpOracleLib.sol";
contract ConcreteUSDeTest is Test {
    using PendleLpOracleLib for IPMarket;

    PendleLPOracle feed;
    PendleLPOracle feedSUsde;
   
    AggregatorV3Interface usdeUSD = AggregatorV3Interface(0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961);
    AggregatorV3Interface sUsdeUSD = AggregatorV3Interface(0xFF3BC18cCBd5999CE63E788A1c250a88626aD099);

    address ptOracle = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2; // pendle PT oracle
    address pendleMarket = 0xe6DF8d8879595100E4B6B359E6D0712E107C7472; // USDe market
    address pendleSMarket = 0xAD016C9565A4aEEC6d4cFC8a01c648eCbea1A602; // sUSDe markets
    uint256 stalePeriod = 24 hours; // USDE/USD chainlink aggregator stale period
    uint32 twapWindow = 180; // TWAP window in seconds
    function setUp() public {
        vm.createSelectFork("mainnet");
        
        feed = new PendleLPOracle(ptOracle,pendleMarket,twapWindow,usdeUSD,stalePeriod);
        
        feedSUsde = new PendleLPOracle(ptOracle,pendleSMarket,twapWindow,sUsdeUSD,stalePeriod);

        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPYLpOracle.getOracleState.selector, pendleMarket, 180),
            abi.encode(false, 0, true)
        );

        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPYLpOracle.getOracleState.selector, pendleSMarket, 180),
            abi.encode(false, 0, true)
        );
    }

    function test_deploy() public {
        assertNotEq(address(feed), address(0));
        assertTrue(feed.getStatus(address(0)));
        assertNotEq(address(feedSUsde), address(0));
        assertTrue(feedSUsde.getStatus(address(0)));
    }

    function test_latestRoundData_USDe() public {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = usdeUSD.latestRoundData();
        console.log(uint(price));
        uint256 lpRate = IPMarket(pendleMarket).getLpToAssetRate(twapWindow);
        console.log(lpRate);
        
        uint256 lpPrice = feed.spot(address(0));
        console.log(lpPrice);
        assertEq(uint(price) * lpRate / 1e8, lpPrice);
    }


    function test_latestRoundData_sUSDe() public {
         (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = sUsdeUSD.latestRoundData();
            console.log(uint(price));
        uint256 lpRate = IPMarket(pendleSMarket).getLpToAssetRate(twapWindow);
        console.log(lpRate);
        
        uint256 lpPrice = feedSUsde.spot(address(0));
        console.log(lpPrice);
        assertEq(uint(price) * lpRate / 1e8, lpPrice);
    }
  
}
