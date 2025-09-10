pragma solidity ^0.8.17;

import "forge-std/Test.sol";


import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {wdiv, wmul} from "../../utils/Math.sol";
import {AggregatorV3CurveScrvUSD} from "src/oracle/AggregatorV3CurveScrvUSD.sol";
import {ChainlinkOracle, AggregatorV3Interface} from "src/oracle/ChainlinkOracle.sol";

contract ScrvUSDXDCFeedTest is Test {
    ChainlinkOracle feed;
    AggregatorV3CurveScrvUSD internal curveOracle;

    address curvePool = 0x24894F0c4f80837d61CA21730A75Fa216FED7200; // scrvUSD/USDC.e pool
    address scrvUSDRateXDC = 0x09F8D940EAD55853c51045bcbfE67341B686C071;
    address scrvUSD = 0x3d8EADb739D1Ef95dd53D718e4810721837c69c1; // scrvUSD on XDC
    uint256 k = 0; // returns USDC/scrvUSD(normalized) price
   

    function setUp() public {
        vm.createSelectFork("xdc");
        curveOracle = new AggregatorV3CurveScrvUSD(curvePool,k, true, scrvUSDRateXDC); // we want to invert to get cUSDO/USDC price (normalized)
        feed = ChainlinkOracle(
            address(
                new ERC1967Proxy(
                    address(
                        new ChainlinkOracle() 
                    ),
                    abi.encodeWithSelector(ChainlinkOracle.initialize.selector, address(this), address(this))
                )
            )
        );
        address[] memory tokens = new address[](1);
        ChainlinkOracle.Oracle[] memory oracles = new ChainlinkOracle.Oracle[](1);
        tokens[0] = scrvUSD;
        oracles[0] = ChainlinkOracle.Oracle(AggregatorV3Interface(address(curveOracle)), 1, 1e18);
        feed.setOracles(tokens,oracles);
        assertTrue(feed.getStatus(scrvUSD));
    }

    function test_deploy() public {
        assertNotEq(address(feed), address(0));
    }

    function test_spot() public {
        // get the price from the curve oracle and invert it to get scrvUSD/USDC
        uint256 usdcScrvUSDPrice = curveOracle.pool().price_oracle(k);
        uint256 scrvUSDusdc =  1e36 / usdcScrvUSDPrice;
        //multiply scrvUSD/USDC normalized with exchange rate to get scrvUSD/USDC
        uint256 price = curveOracle.scrvUSDOracle().price_v0() * uint256(scrvUSDusdc) / 10 ** AggregatorV3CurveScrvUSD(curveOracle).decimals();
        assertEq(price, feed.spot(scrvUSD));
        (, int256 answer, ,uint256 updatedAt , ) = AggregatorV3CurveScrvUSD(curveOracle).latestRoundData();
        assertEq(uint(answer), price);
        assertEq(updatedAt, block.timestamp);
        console2.log("price", feed.spot(scrvUSD));
    }
}
