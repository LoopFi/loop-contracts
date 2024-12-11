// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "../../utils/Math.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SpectraYnETHOracle, ICurvePool} from "../../oracle/SpectraYnETHOracle.sol";

contract SpectraYnETHOracleTest is Test {
    SpectraYnETHOracle internal spectraOracle;
    // SPECTRA ynETH
    address internal constant SPECTRA_ROUTER = 0x3d20601ac0Ba9CAE4564dDf7870825c505B69F1a;
    address curvePool = address(0x08DA2b1EA8f2098D44C8690dDAdCa3d816c7C0d5); // Spectra ynETH PT-sw-ynETH / sw-ynETH
    address lpTokenTracker = address(0x85F05383f7Cb67f35385F7bF3B74E68F4795CbB9);
    address swYnETH = address(0x6e0dccf49D095F8ea8920A8aF03D236FA167B7E0);
    address pTswYnETH = address(0x57E9EBeB30852D31f99A08E39068d93b0D8FC917);
    address ynETH = address(0x09db87A538BD693E9d08544577d5cCfAA6373A48);
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        spectraOracle = SpectraYnETHOracle(
            address(
                new ERC1967Proxy(
                    address(new SpectraYnETHOracle(curvePool, ynETH, swYnETH)),
                    abi.encodeWithSelector(SpectraYnETHOracle.initialize.selector, address(this), address(this))
                )
            )
        );
    }

    function test_deployOracle() public {
        assertTrue(address(spectraOracle) != address(0));
        assertEq(address(spectraOracle.curvePool()), curvePool);
        assertEq(address(spectraOracle.ynETH()), ynETH);
        assertEq(address(spectraOracle.spectraYnETH()), address(swYnETH));
    }

    function test_oracle_price() public view {
        console.log(spectraOracle.spot(address(0)));
    }

    function test_spot() public {
        uint256 spectraYnETHVirtualPrice = ICurvePool(curvePool).lp_price();
        uint256 lpPriceInETH = ERC4626(swYnETH).convertToAssets(spectraYnETHVirtualPrice);
        assertEq(spectraOracle.spot(address(0)), lpPriceInETH);
    }

    function test_getStatus() public {
        assertTrue(spectraOracle.getStatus(address(0)));
    }

    function test_upgradeOracle() public {
        spectraOracle.upgradeTo(address(new SpectraYnETHOracle(address(0x1), address(0x2), address(0x3))));
        assertTrue(address(spectraOracle) != address(0));
        assertEq(address(spectraOracle.curvePool()), address(0x1));
        assertEq(address(spectraOracle.ynETH()), address(0x2));
        assertEq(address(spectraOracle.spectraYnETH()), address(0x3));
    }

    function test_upgradeOracle_revertsOnUnauthorized() public {
        // attempt to upgrade from an unauthorized address
        vm.startPrank(address(0x123123));
        address newImplementation = address(new SpectraYnETHOracle(address(0x1), address(0x2), address(0x3)));

        vm.expectRevert();
        spectraOracle.upgradeTo(newImplementation);
        vm.stopPrank();
    }
}
