pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {PendleLPOracleRate, AggregatorV3Interface} from "src/oracle/PendleLPOracleRate.sol";
import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import {PendleLpOracleLib} from "pendle/oracles/PendleLpOracleLib.sol";
import {IPPtOracle} from "pendle/interfaces/IPPtOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {wdiv, wmul} from "../../utils/Math.sol";


contract TEthFeedTest is Test {
    using PendleLpOracleLib for IPMarket;
  
    PendleLPOracleRate feed;

    address market = 0xBDb8F9729d3194f75fD1A3D9bc4FFe0DDe3A404c; // tETH market 28 may 25
    address ptOracle = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2; // pendle PT oracle
    uint32 twap = 180;

    function setUp() public {
        vm.createSelectFork("mainnet");

        feed = PendleLPOracleRate(
            address(
                new ERC1967Proxy(
                    address(
                        new PendleLPOracleRate(ptOracle, market, twap)
                    ),
                    abi.encodeWithSelector(PendleLPOracleRate.initialize.selector, address(this), address(this))
                )
            )
        );

        assertTrue(feed.getStatus(address(0)));
    }

    function test_deploy() public {
        assertNotEq(address(feed), address(0));
    }

    function test_spot() public {
        assertEq(IPMarket(market).getLpToAssetRate(twap), feed.spot(address(0)));
        console.log("price", feed.spot(address(0)));
    }

}
