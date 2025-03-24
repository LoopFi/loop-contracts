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

contract PendleLPOracleTest is IntegrationTestBase {
    using PendleLpOracleLib for IPMarket;
    PendleLPOracle internal pendleOracle;

    uint256 internal staleTime = 10 days;
    address market = 0xcbA3B226cA62e666042Cb4a1e6E4681053885F75; // weETHs
    address weETHChainlink = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22; // weETH/ETH chainlink feed
    address ptOracle = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2; // pendle PT oracle

    function setUp() public override {
        usePatchedDeal = true;
        super.setUp();

        pendleOracle = PendleLPOracle(
            address(
                new ERC1967Proxy(
                    address(
                        new PendleLPOracle(ptOracle, market, 180, AggregatorV3Interface(weETHChainlink), staleTime)
                    ),
                    abi.encodeWithSelector(PendleLPOracle.initialize.selector, address(this), address(this))
                )
            )
        );
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 21739729;
    }

    function test_deployOracle() public {
        assertTrue(address(pendleOracle) != address(0));
    }

    function test_spot(address token) public {
        (, int256 answer, , , ) = AggregatorV3Interface(weETHChainlink).latestRoundData();
        uint256 scaledAnswer = wdiv(uint256(answer), 10 ** AggregatorV3Interface(weETHChainlink).decimals());
        uint256 weETHRate = IPMarket(market).getLpToAssetRate(180);
        assertEq(pendleOracle.spot(token), wmul(scaledAnswer, weETHRate));
    }

    function test_getStatus() public {
        assertTrue(pendleOracle.getStatus(address(0)));
    }

    function test_getStatus_returnsFalseOnStaleValue() public {
        vm.warp(block.timestamp + staleTime + 1);
        assertTrue(pendleOracle.getStatus(address(0)) == false);
    }

    function test_getStatus_returnsFalseOnPendleInvalidValue() public {
        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPYLpOracle.getOracleState.selector, market, 180),
            abi.encode(true, 0, true)
        );
        assertTrue(pendleOracle.getStatus(address(0)) == false);

        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPYLpOracle.getOracleState.selector, market, 180),
            abi.encode(false, 0, false)
        );
        assertTrue(pendleOracle.getStatus(address(0)) == false);

        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPYLpOracle.getOracleState.selector, market, 180),
            abi.encode(false, 0, true)
        );
        assertTrue(pendleOracle.getStatus(address(0)));
    }

    function test_spot_revertsOnStaleValue(address token) public {
        vm.warp(block.timestamp + staleTime + 1);

        vm.expectRevert(PendleLPOracle.PendleLPOracle__spot_invalidValue.selector);
        pendleOracle.spot(token);
    }

    function test_upgradeOracle() public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1);
        pendleOracle.upgradeTo(
            address(new PendleLPOracle(ptOracle, market, 180, AggregatorV3Interface(weETHChainlink), newStaleTime))
        );

        assertTrue(address(pendleOracle.aggregator()) == weETHChainlink);
        assertEq(pendleOracle.stalePeriod(), newStaleTime);
    }

    function test_upgradeOracle_revertsOnValidState() public {
        // the value returned is valid so the upgrade should revert
        uint256 newStaleTime = staleTime + 1 days;

        address newImplementation = address(
            new PendleLPOracle(ptOracle, market, 180, AggregatorV3Interface(weETHChainlink), newStaleTime)
        );
        vm.expectRevert(PendleLPOracle.PendleLPOracle__authorizeUpgrade_validStatus.selector);
        pendleOracle.upgradeTo(newImplementation);
    }

    function test_upgradeOracle_revertsOnUnauthorized() public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1);

        // attempt to upgrade from an unauthorized address
        vm.startPrank(address(0x123123));
        address newImplementation = address(
            new PendleLPOracle(ptOracle, market, 180, AggregatorV3Interface(weETHChainlink), newStaleTime)
        );

        vm.expectRevert();
        pendleOracle.upgradeTo(newImplementation);
        vm.stopPrank();
    }

    function test_upgradeOracle_usesNewFeed(address token) public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1);
        pendleOracle.upgradeTo(
            address(new PendleLPOracle(ptOracle, market, 180, AggregatorV3Interface(weETHChainlink), newStaleTime))
        );

        (, int256 answer, , , ) = AggregatorV3Interface(weETHChainlink).latestRoundData();
        uint256 scaledAnswer = wdiv(uint256(answer), 10 ** AggregatorV3Interface(weETHChainlink).decimals());
        uint256 weETHRate = IPMarket(market).getLpToAssetRate(180);
        assertEq(pendleOracle.spot(token), wmul(scaledAnswer, weETHRate));
    }
}
