pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {PendleLPOracle} from "src/oracle/PendleLPOracle.sol";
import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import {PendleLpOracleLib} from "pendle/oracles/PtYtLpOracle/PendleLpOracleLib.sol";
import {IPPYLpOracle} from "pendle/interfaces/IPPYLpOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {wdiv, wmul} from "../../utils/Math.sol";
import {AggregatorV3Curve} from "src/oracle/AggregatorV3Curve.sol";
import {AggregatorV3Interface} from "src/vendor/AggregatorV3Interface.sol";

contract CUSDOFeedTest is Test {
    using PendleLpOracleLib for IPMarket;
  
    PendleLPOracle feed;
    AggregatorV3Curve internal curveOracle;

    address curvePool = 0x90455bd11Ce8a67C57d467e634Dc142b8e4105Aa; // cUSDO/USDC curve pool
    uint256 k = 0; // returns USDC/cUSDO(normalized) price
    address market = 0xA77c0DE4d26B7C97D1D42ABD6733201206122E25; // cUSDO 18 June 25
    address ptOracle = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2; // pendle PT oracle
    uint32 twap = 180;

    function setUp() public {
        vm.createSelectFork("mainnet");
        curveOracle = new AggregatorV3Curve(curvePool,k, true); // we want to invert to get cUSDO/USDC price (normalized)
        feed = PendleLPOracle(
            address(
                new ERC1967Proxy(
                    address(
                        new PendleLPOracle(ptOracle, market, twap, AggregatorV3Interface(address(curveOracle)), 1) // 1 second stale time
                    ),
                    abi.encodeWithSelector(PendleLPOracle.initialize.selector, address(this), address(this))
                )
            )
        );

        assertTrue(feed.getStatus(address(0)));
    }

    function test_deploy() public {
        assertNotEq(address(feed), address(0));
    }

    function test_spot() public {
        // get the price from the curve oracle
        (, int256 answer, , , ) = AggregatorV3Curve(curveOracle).latestRoundData();
        uint256 price = IPMarket(market).getLpToAssetRate(twap) * uint256(answer) / 10 ** AggregatorV3Curve(curveOracle).decimals();
        assertEq(price, feed.spot(address(0)));
        console2.log("price", feed.spot(address(0)));
    }

}
