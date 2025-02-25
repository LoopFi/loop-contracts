pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {PendleLPOracle, AggregatorV3Interface} from "src/oracle/PendleLPOracle.sol";
import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import {PendleLpOracleLib} from "pendle/oracles/PendleLpOracleLib.sol";
import {IPPtOracle} from "pendle/interfaces/IPPtOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {wdiv, wmul} from "../../utils/Math.sol";
import {AggregatorV3WstEthOracle} from "src/oracle/AggregatorV3WstEthOracle.sol";
import {CombinedAggregatorV3Oracle} from "src/oracle/CombinedAggregatorV3Oracle.sol";

contract TEthFeedTest is Test {
    using PendleLpOracleLib for IPMarket;
    AggregatorV3WstEthOracle wstEthToStEth;
    CombinedAggregatorV3Oracle wstEthToEth;
    CombinedAggregatorV3Oracle tEthToEth;
    PendleLPOracle feed;

    address wstEth = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address stEthToEthFeed = address(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);
    uint256 stEthToEthFeedHeartbeat = 86400;
    address tEthToWstEthExchangeRate = address(0x7B2Fb2c667af80Bccc0B2556378352dFDE2be914);
    uint256 tEthToWstEthExchangeRateHeartbeat = 86400;

    address market = 0xBDb8F9729d3194f75fD1A3D9bc4FFe0DDe3A404c; // tETH market 28 may 25
    address ptOracle = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2; // pendle PT oracle
 

    function setUp() public {
        vm.createSelectFork("mainnet");

        wstEthToStEth = new AggregatorV3WstEthOracle(wstEth);
        wstEthToEth = new CombinedAggregatorV3Oracle(stEthToEthFeed, stEthToEthFeedHeartbeat, address(wstEthToStEth), 1, true);
        tEthToEth = new CombinedAggregatorV3Oracle(tEthToWstEthExchangeRate, tEthToWstEthExchangeRateHeartbeat, address(wstEthToEth), stEthToEthFeedHeartbeat, true);
        feed = PendleLPOracle(
            address(
                new ERC1967Proxy(
                    address(
                        new PendleLPOracle(ptOracle, market, 180, AggregatorV3Interface(address(tEthToEth)), tEthToWstEthExchangeRateHeartbeat)
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
        (, int256 tEthToEthRate, , uint256 updateAt, ) = tEthToEth.latestRoundData();
        console.log(" wstEthToStEthRate", uint(tEthToEthRate));

        (, int256 wstEthToEthRate, , , ) = wstEthToEth.latestRoundData();
        (, int256 clStEthToEthRate, , , ) = AggregatorV3Interface(stEthToEthFeed).latestRoundData();
        (,int256 wstEthToStEthRate, , , ) = wstEthToStEth.latestRoundData();
        assertEq(uint(wstEthToEthRate), wmul(uint(wstEthToStEthRate), uint(clStEthToEthRate)));

        (, int256 cltEthToWstEthRate, ,uint256 updateAtTEthToWstEth , ) = AggregatorV3Interface(tEthToWstEthExchangeRate).latestRoundData();
        
        assertEq(uint(tEthToEthRate), wmul(uint(cltEthToWstEthRate), uint(wstEthToEthRate)));
        assertEq(updateAtTEthToWstEth, updateAt);
        console.log("price", feed.spot(address(0)));
    }

}
