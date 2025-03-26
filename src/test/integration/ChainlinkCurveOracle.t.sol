// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "../../utils/Math.sol";

import {PendleLPOracle} from "../../oracle/PendleLPOracle.sol";

import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import {PendleLpOracleLib} from "pendle/oracles/PtYtLpOracle/PendleLpOracleLib.sol";
import {IPPYLpOracle} from "pendle/interfaces/IPPYLpOracle.sol";
import {ChainlinkCurveOracle} from "../../oracle/ChainlinkCurveOracle.sol";
import {Combined4626AggregatorV3Oracle} from "../../oracle/Combined4626AggregatorV3Oracle.sol";
import {CombinedAggregatorV3Oracle} from "../../oracle/CombinedAggregatorV3Oracle.sol";

contract ChainlinkCurveOracleIntegrationTest is IntegrationTestBase {
    using PendleLpOracleLib for IPMarket;
    

    address public curvePool = 0xFb7c3C95f4C2C05F6eC7dcFE3e368a40eB338603;
    address public deUSDFeed = 0x89F48f6671Ec1B1C4f6abE964EBdd21F4eb7076f;
    uint256 public heartbeat = 43200; // 12 hours
    address public sdeUSDVault = 0x5C5b196aBE0d54485975D1Ec29617D42D9198326;
    uint256 public stalePeriod = 86400;
    address public usdc_aggregator = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    uint256 public usdc_heartbeat = 86400; // 24 hours

    ChainlinkCurveOracle internal chainlinkCurveOracle;

    function setUp() public override {
        usePatchedDeal = true;
        super.setUp();

        Combined4626AggregatorV3Oracle combined4626AggregatorV3Oracle = new Combined4626AggregatorV3Oracle(
            deUSDFeed,
            heartbeat,
            sdeUSDVault
        );

        CombinedAggregatorV3Oracle combinedAggregatorV3Oracle = new CombinedAggregatorV3Oracle(
            address(combined4626AggregatorV3Oracle),
            heartbeat,
            usdc_aggregator,
            usdc_heartbeat,
            false
        );
        
        chainlinkCurveOracle = new ChainlinkCurveOracle(
            address(combinedAggregatorV3Oracle),
            curvePool,
            stalePeriod
        );
        
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 21739729;
    }

    function test_deployOracle() public {
        assertTrue(address(chainlinkCurveOracle) != address(0));
    }

    function test_spot(address token) public {
        uint256 spot = chainlinkCurveOracle.spot(token);
        assertGt(spot, 1e18);
    }

    function test_getStatus() public {
        assertTrue(chainlinkCurveOracle.getStatus(address(0)));
    }
}
