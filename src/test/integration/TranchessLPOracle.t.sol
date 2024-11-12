// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "../../utils/Math.sol";

import {TranchessLPOracle, IStableSwapV2} from "../../oracle/TranchessLPOracle.sol";

contract TranchessLPOracleTest is Test {
    TranchessLPOracle internal tranchessOracle;

    uint256 internal staleTime = 24 hours;
    address stableSwap = address(0xEC8bFa1D15842D6B670d11777A08c39B09A5FF00); // tranchess stableswap
    address stoneEthChainlink = address(0x0E4d8D665dA14D35444f0eCADc82F78a804A5F95); // stone/eth chainlink feed
    address fund = address(0x4B0D5Fe3C1F58FD68D20651A5bC761553C10D955); // tranchess fund 2 stone
    address lpToken = address(0xD48Cc42e154775f8a65EEa1D6FA1a11A31B09B65); // tranchess lp token (liquidity gauge)
    uint256 settledDay = 1727877600;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("scroll"), getForkBlockNumber());

        tranchessOracle = TranchessLPOracle(
            address(
                new ERC1967Proxy(
                    address(new TranchessLPOracle(stableSwap, AggregatorV3Interface(stoneEthChainlink), staleTime)),
                    abi.encodeWithSelector(TranchessLPOracle.initialize.selector, address(this), address(this))
                )
            )
        );
    }

    function getForkBlockNumber() internal pure returns (uint256) {
        return 10571967;
    }

    function test_deployOracle() public {
        assertTrue(address(tranchessOracle) != address(0));
        assertEq(tranchessOracle.stalePeriod(), staleTime);
        assertEq(address(tranchessOracle.stableSwap()), stableSwap);
        assertEq(address(tranchessOracle.aggregator()), stoneEthChainlink);
    }

    function test_oracle_price() public view {
        console.log(tranchessOracle.spot(address(0)));
    }

    function test_spot() public {
        (, int256 answer, , , ) = AggregatorV3Interface(stoneEthChainlink).latestRoundData();
        uint256 scaledAnswer = wdiv(uint256(answer), 10 ** AggregatorV3Interface(stoneEthChainlink).decimals());
        uint256 lpVirtualPrice = IStableSwapV2(stableSwap).getCurrentPrice();
        assertEq(tranchessOracle.spot(address(0)), wmul(lpVirtualPrice, scaledAnswer));
    }

    function test_getStatus() public {
        assertTrue(tranchessOracle.getStatus(address(0)));
    }

    function test_getStatus_returnsFalseOnStaleValue() public {
        vm.warp(block.timestamp + staleTime + 1);
        assertTrue(tranchessOracle.getStatus(address(0)) == false);
    }

    function test_spot_revertsOnStaleValue() public {
        vm.warp(block.timestamp + staleTime + 1);

        vm.expectRevert(TranchessLPOracle.TranchessLPOracle__spot_invalidValue.selector);
        tranchessOracle.spot(address(0));
    }

    function test_upgradeOracle() public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1);
        tranchessOracle.upgradeTo(
            address(new TranchessLPOracle(stableSwap, AggregatorV3Interface(stoneEthChainlink), newStaleTime))
        );

        assertTrue(address(tranchessOracle.aggregator()) == stoneEthChainlink);
        assertEq(tranchessOracle.stalePeriod(), newStaleTime);
    }

    function test_upgradeOracle_revertsOnValidState() public {
        // the value returned is valid so the upgrade should revert
        uint256 newStaleTime = staleTime + 1 days;

        address newImplementation = address(
            new TranchessLPOracle(stableSwap, AggregatorV3Interface(stoneEthChainlink), newStaleTime)
        );
        vm.expectRevert(TranchessLPOracle.TranchessLPOracle__authorizeUpgrade_validStatus.selector);
        tranchessOracle.upgradeTo(newImplementation);
    }

    function test_upgradeOracle_revertsOnUnauthorized() public {
        uint256 newStaleTime = staleTime + 1 days;
        // warp time so that the value is stale
        vm.warp(block.timestamp + staleTime + 1);

        // attempt to upgrade from an unauthorized address
        vm.startPrank(address(0x123123));
        address newImplementation = address(
            new TranchessLPOracle(stableSwap, AggregatorV3Interface(stoneEthChainlink), newStaleTime)
        );

        vm.expectRevert();
        tranchessOracle.upgradeTo(newImplementation);
        vm.stopPrank();
    }
}
