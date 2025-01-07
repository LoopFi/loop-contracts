// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {AggregatorV3Interface} from "../../vendor/AggregatorV3Interface.sol";

import {wdiv, wmul} from "../../utils/Math.sol";

import {PendleLPOracle4626} from "../../oracle/PendleLPOracle4626.sol";

import {IPMarket} from "pendle/interfaces/IPMarket.sol";
import {PendleLpOracleLib} from "pendle/oracles/PendleLpOracleLib.sol";
import {IPPtOracle} from "pendle/interfaces/IPPtOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {console} from "forge-std/console.sol";
contract PendleLPOracle4626Test is IntegrationTestBase {
    using PendleLpOracleLib for IPMarket;
    PendleLPOracle4626 internal pendleOracle;

    uint32 twap = 3600;
    address market = 0x58612beB0e8a126735b19BB222cbC7fC2C162D2a; // PufETH JUN 2025
    address pufETH = 0xD9A442856C234a39a81a089C06451EBAa4306a72; // PufETH
    address ptOracle = 0x66a1096C6366b2529274dF4f5D8247827fe4CEA8; // pendle PT oracle

    function setUp() public override {
        usePatchedDeal = true;
        super.setUp();

        pendleOracle = PendleLPOracle4626(
            address(
                new ERC1967Proxy(
                    address(new PendleLPOracle4626(ptOracle, market, twap, pufETH)),
                    abi.encodeWithSelector(PendleLPOracle4626.initialize.selector, address(this), address(this))
                )
            )
        );
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 21187325;
    }

    function test_deployOracle() public {
        assertTrue(address(pendleOracle) != address(0));
    }

    function test_spot(address token) public {
        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPtOracle.getOracleState.selector, market, twap),
            abi.encode(false, 0, true)
        );
        uint256 scaledAnswer = IERC4626(pufETH).convertToAssets(1 ether);
        uint256 pufETHRate = IPMarket(market).getLpToAssetRate(twap);

        assertEq(pendleOracle.spot(token), wmul(scaledAnswer, pufETHRate));
        assertEq(pendleOracle.spot(token), IERC4626(pufETH).convertToAssets(pufETHRate));
    }

    function test_getStatus() public {
        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPtOracle.getOracleState.selector, market, twap),
            abi.encode(false, 0, true)
        );
        console.log(pendleOracle.getStatus(address(0)));
        assertTrue(pendleOracle.getStatus(address(0)));
    }

    function test_getStatus_returnsFalseOnPendleInvalidValue() public {
        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPtOracle.getOracleState.selector, market, twap),
            abi.encode(true, 0, true)
        );
        assertTrue(pendleOracle.getStatus(address(0)) == false);

        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPtOracle.getOracleState.selector, market, twap),
            abi.encode(false, 0, false)
        );
        assertTrue(pendleOracle.getStatus(address(0)) == false);

        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPtOracle.getOracleState.selector, market, twap),
            abi.encode(false, 0, true)
        );
        assertTrue(pendleOracle.getStatus(address(0)));
    }

    function test_upgradeOracle() public {
        pendleOracle.upgradeTo(address(new PendleLPOracle4626(ptOracle, market, twap, address(1))));

        assertEq(address(pendleOracle.vault()), address(1));
    }

    function test_upgradeOracle_revertsOnValidState() public {
        vm.mockCall(
            ptOracle,
            abi.encodeWithSelector(IPPtOracle.getOracleState.selector, market, twap),
            abi.encode(false, 0, true)
        );
        address newImplementation = address(new PendleLPOracle4626(ptOracle, market, twap, pufETH));
        vm.expectRevert(PendleLPOracle4626.PendleLPOracle__authorizeUpgrade_validStatus.selector);
        pendleOracle.upgradeTo(newImplementation);
    }

    function test_upgradeOracle_revertsOnUnauthorized() public {
        // attempt to upgrade from an unauthorized address
        vm.startPrank(address(0x123123));
        address newImplementation = address(new PendleLPOracle4626(ptOracle, market, twap, pufETH));

        vm.expectRevert();
        pendleOracle.upgradeTo(newImplementation);
        vm.stopPrank();
    }
}
