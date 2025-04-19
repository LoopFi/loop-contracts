// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test, console2} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "../../utils/Math.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SpectraAggregatorV3Oracle, ICurvePool} from "../../oracle/SpectraAggregatorV3Oracle.sol";
import {AggregatorV3WstEthOracle} from "../../oracle/AggregatorV3WstEthOracle.sol";
import {CombinedAggregatorV3Oracle} from "../../oracle/CombinedAggregatorV3Oracle.sol";
contract SpectraInwstETHOracleTest is Test {
    AggregatorV3WstEthOracle internal wstETHOracle; // wstETH to stETH oracle
    CombinedAggregatorV3Oracle internal combinedOracle; // stETH to ETH oracle
    SpectraAggregatorV3Oracle internal spectraOracle; // inwstETH to ETH oracle
    // SPECTRA InwstETH
    address internal constant SPECTRA_ROUTER = 0x3d20601ac0Ba9CAE4564dDf7870825c505B69F1a;
    address curvePool = address(0xE119bad8a35B999f65b1e5Fd48c626C327DAa16B); // Spectra inwstETH PT-sw-inwstETH / sw-inwstETH
    address lpTokenTracker = address(0x2cd244f1f9A856C251d276103862dD4325985D2A);
    address spectraIBT = address(0xd89Fc47AacBB31E2bF23EC599F593A4876D8c18C);
    address wstETH = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address stETH = address(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address stETHClOracle = address(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);
    uint256 stalePeriod = 24 hours;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        wstETHOracle = new AggregatorV3WstEthOracle(wstETH);
        combinedOracle = new CombinedAggregatorV3Oracle(
            address(wstETHOracle),
            1, // 1 seconds heartbeat, wstETH Oracle returns the timestamp
            stETHClOracle,
            stalePeriod,
            true // true for mul, false for div
        );
        spectraOracle = SpectraAggregatorV3Oracle(
            address(
                new ERC1967Proxy(
                    address(new SpectraAggregatorV3Oracle(curvePool, spectraIBT, AggregatorV3Interface(address(combinedOracle)), stalePeriod)),
                    abi.encodeWithSelector(SpectraAggregatorV3Oracle.initialize.selector, address(this), address(this))
                )
            )
        );
    }

    function test_deployOracle() public {
        assertTrue(address(spectraOracle) != address(0));
        assertEq(address(spectraOracle.curvePool()), curvePool);
        assertEq(address(spectraOracle.spectraIBT()), address(spectraIBT));
        assertEq(address(spectraOracle.aggregator()), address(combinedOracle));
        assertEq(spectraOracle.stalePeriod(),stalePeriod);
        assertEq(spectraOracle.aggregatorScale(), 10 ** uint256(combinedOracle.decimals()));
        assertEq(spectraOracle.aggregatorScale(), 10 ** 18);
    }

    function test_oracle_price() public view {
        console2.log(spectraOracle.spot(address(0)));
    }

    function test_spot() public {
        uint256 spectraWstETHVirtualPrice = ICurvePool(curvePool).lp_price();
        uint256 lpPriceInWstETH = ERC4626(spectraIBT).convertToAssets(spectraWstETHVirtualPrice);
        (,int256 combinedPrice,,,) = combinedOracle.latestRoundData();
        console2.log("combinedPrice", uint(combinedPrice));
        console2.log("lpPriceInWstETH", lpPriceInWstETH);
        console2.log("spectraWstETHVirtualPrice", spectraWstETHVirtualPrice);
        console2.log("spectraOracle.spot", spectraOracle.spot(address(0)));
        assertEq(spectraOracle.spot(address(0)), wmul(uint(combinedPrice), lpPriceInWstETH));
    }

    function test_getStatus() public {
        assertTrue(spectraOracle.getStatus(address(0)));
    }

    function test_upgradeOracle_reverts_validStatus() public {
        address newImplementation = address(new SpectraAggregatorV3Oracle(address(0x1), address(0x2),AggregatorV3Interface(address(combinedOracle)), 1));
        vm.expectRevert(SpectraAggregatorV3Oracle.SpectraAggregatorV3Oracle__authorizeUpgrade_validStatus.selector);
        spectraOracle.upgradeTo(newImplementation);
    }

    function test_upgradeOracle_succeds_if_not_validStatus() public {
        vm.warp(block.timestamp + 2 days);
        address newImplementation = address(new SpectraAggregatorV3Oracle(address(0x1), address(0x2),AggregatorV3Interface(address(combinedOracle)), 1));
        spectraOracle.upgradeTo(newImplementation);
        assertTrue(address(spectraOracle) != address(0));
        assertEq(address(spectraOracle.curvePool()), address(0x1));
        assertEq(address(spectraOracle.spectraIBT()), address(0x2));
    }


    function test_upgradeOracle_revertsOnUnauthorized() public {
        // attempt to upgrade from an unauthorized address
        vm.startPrank(address(0x123123));
        address newImplementation = address(new SpectraAggregatorV3Oracle(address(0x1), address(0x2),AggregatorV3Interface(address(combinedOracle)), 1));

        vm.expectRevert();
        spectraOracle.upgradeTo(newImplementation);
        vm.stopPrank();
    }
}
