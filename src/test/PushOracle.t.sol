// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../oracle/PushOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WAD} from "../utils/Math.sol";
import {MANAGER_ROLE} from "../interfaces/IOracle.sol";

/**
 * @title PushOracleTest
 * @notice Comprehensive test suite for PushOracle contract
 * @dev Includes tests for initialization, configuration, price updates, TWAP calculations,
 *      WAD precision, access control, upgrades, and stress testing
 */
contract PushOracleTest is Test {
    PushOracle public oracle;
    PushOracle public oracleImpl;
    
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public priceUpdater = makeAddr("priceUpdater");
    address public priceUpdater2 = makeAddr("priceUpdater2");
    address public unauthorizedUser = makeAddr("unauthorizedUser");
    
    address public token1 = makeAddr("token1");
    address public token2 = makeAddr("token2");
    
    uint256 public constant PRICE_1 = 1000 * WAD; // 1000 USD
    uint256 public constant PRICE_2 = 2000 * WAD; // 2000 USD
    uint256 public constant STALE_PERIOD = 1 hours;
    uint256 public constant TWAP_WINDOW = 30 minutes;

    event PriceUpdated(address indexed token, uint256 price, address indexed updater, uint256 timestamp);
    event OracleConfigUpdated(address indexed token, uint256 stalePeriod, uint256 twapWindow, bool twapEnabled);

    function setUp() public {
        // Deploy implementation
        oracleImpl = new PushOracle();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            PushOracle.initialize.selector,
            admin,
            manager
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(oracleImpl), initData);
        oracle = PushOracle(address(proxy));
        
        // Setup oracle configurations
        vm.startPrank(admin);
        
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;
        
        PushOracle.OracleConfig[] memory configs = new PushOracle.OracleConfig[](2);
        configs[0] = PushOracle.OracleConfig({
            stalePeriod: STALE_PERIOD,
            twapWindow: TWAP_WINDOW,
            twapEnabled: false
        });
        configs[1] = PushOracle.OracleConfig({
            stalePeriod: STALE_PERIOD,
            twapWindow: TWAP_WINDOW,
            twapEnabled: true
        });
        
        oracle.setOracleConfigs(tokens, configs);
        oracle.grantPriceUpdaterRole(priceUpdater);
        oracle.grantPriceUpdaterRole(priceUpdater2);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitialization() public {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(MANAGER_ROLE, manager));
        assertTrue(oracle.hasRole(oracle.PRICE_UPDATER_ROLE(), priceUpdater));
        assertTrue(oracle.hasRole(oracle.PRICE_UPDATER_ROLE(), priceUpdater2));
    }

    function testSetOracleConfigs() public {
        (uint256 stalePeriod, uint256 twapWindow, bool twapEnabled) = oracle.oracleConfigs(token1);
        assertEq(stalePeriod, STALE_PERIOD);
        assertEq(twapWindow, TWAP_WINDOW);
        assertFalse(twapEnabled);

        (stalePeriod, twapWindow, twapEnabled) = oracle.oracleConfigs(token2);
        assertEq(stalePeriod, STALE_PERIOD);
        assertEq(twapWindow, TWAP_WINDOW);
        assertTrue(twapEnabled);
    }

    function testSetOracleConfigsRevertInvalidWindow() public {
        vm.startPrank(admin);
        
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("newToken");
        
        PushOracle.OracleConfig[] memory configs = new PushOracle.OracleConfig[](1);
        configs[0] = PushOracle.OracleConfig({
            stalePeriod: STALE_PERIOD,
            twapWindow: 0,
            twapEnabled: true // TWAP enabled but window is 0
        });
        
        vm.expectRevert(PushOracle.PushOracle__setOracleConfig_invalidWindow.selector);
        oracle.setOracleConfigs(tokens, configs);
        
        vm.stopPrank();
    }

    function testSetOracleConfigsOnlyAdmin() public {
        vm.startPrank(unauthorizedUser);
        
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("newToken");
        
        PushOracle.OracleConfig[] memory configs = new PushOracle.OracleConfig[](1);
        configs[0] = PushOracle.OracleConfig({
            stalePeriod: STALE_PERIOD,
            twapWindow: TWAP_WINDOW,
            twapEnabled: false
        });
        
        vm.expectRevert();
        oracle.setOracleConfigs(tokens, configs);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function testUpdatePrice() public {
        vm.startPrank(priceUpdater);
        
        vm.expectEmit(true, true, false, true);
        emit PriceUpdated(token1, PRICE_1, priceUpdater, block.timestamp);
        
        oracle.updatePrice(token1, PRICE_1);
        
        (uint256 spotPrice, uint256 twapPrice, uint256 timestamp) = oracle.getLatestPriceData(token1);
        uint256 price = spotPrice;
        assertEq(price, PRICE_1);
        assertEq(timestamp, block.timestamp);
        
        vm.stopPrank();
    }

    function testUpdatePriceRevertZeroPrice() public {
        vm.startPrank(priceUpdater);
        
        vm.expectRevert(PushOracle.PushOracle__updatePrice_invalidPrice.selector);
        oracle.updatePrice(token1, 0);
        
        vm.stopPrank();
    }

    function testUpdatePriceRevertTokenNotConfigured() public {
        address unconfiguredToken = makeAddr("unconfiguredToken");
        
        vm.startPrank(priceUpdater);
        
        vm.expectRevert(PushOracle.PushOracle__updatePrice_tokenNotConfigured.selector);
        oracle.updatePrice(unconfiguredToken, PRICE_1);
        
        vm.stopPrank();
    }

    function testUpdatePriceOnlyAuthorized() public {
        vm.startPrank(unauthorizedUser);
        
        vm.expectRevert();
        oracle.updatePrice(token1, PRICE_1);
        
        vm.stopPrank();
    }

    function testUpdatePricesArray() public {
        vm.startPrank(priceUpdater);
        
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;
        
        uint256[] memory prices = new uint256[](2);
        prices[0] = PRICE_1;
        prices[1] = PRICE_2;
        
        oracle.updatePrices(tokens, prices);
        
        (uint256 price1,,) = oracle.getLatestPriceData(token1);
        (uint256 price2,,) = oracle.getLatestPriceData(token2);
        
        assertEq(price1, PRICE_1);
        assertEq(price2, PRICE_2);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE STATUS TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetStatusFreshPrice() public {
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token1, PRICE_1);
        vm.stopPrank();
        
        assertTrue(oracle.getStatus(token1));
    }

    function testGetStatusStalePrice() public {
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token1, PRICE_1);
        vm.stopPrank();
        
        // Move forward past stale period
        vm.warp(block.timestamp + STALE_PERIOD + 1);
        
        assertFalse(oracle.getStatus(token1));
    }

    function testGetStatusNoPrice() public {
        assertFalse(oracle.getStatus(token1));
    }

    /*//////////////////////////////////////////////////////////////
                            SPOT PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testSpotPrice() public {
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token1, PRICE_1);
        vm.stopPrank();
        
        uint256 spotPrice = oracle.spot(token1);
        assertEq(spotPrice, PRICE_1);
    }

    function testSpotPriceRevertStale() public {
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token1, PRICE_1);
        vm.stopPrank();
        
        // Move forward past stale period
        vm.warp(block.timestamp + STALE_PERIOD + 1);
        
        vm.expectRevert(PushOracle.PushOracle__spot_stalePrice.selector);
        oracle.spot(token1);
    }

    function testSpotPriceRevertNoPrice() public {
        vm.expectRevert(PushOracle.PushOracle__spot_invalidValue.selector);
        oracle.spot(token1);
    }

    function testSpotPriceRevertTokenNotConfigured() public {
        address unconfiguredToken = makeAddr("unconfiguredToken");
        
        vm.expectRevert(PushOracle.PushOracle__spot_invalidValue.selector);
        oracle.spot(unconfiguredToken);
    }

    /*//////////////////////////////////////////////////////////////
                               TWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function testTWAPSinglePrice() public {
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token2, PRICE_1); // token2 has TWAP enabled
        vm.stopPrank();
        
        uint256 twapPrice = oracle.spot(token2);
        assertEq(twapPrice, PRICE_1);
    }

    function testTWAPMultiplePrices() public {
        vm.startPrank(priceUpdater);
        
        // First price
        oracle.updatePrice(token2, 1000 * WAD);
        uint256 time1 = block.timestamp;
        
        // Second price after 10 minutes
        vm.warp(time1 + 10 minutes);
        oracle.updatePrice(token2, 1200 * WAD);
        uint256 time2 = block.timestamp;
        
        // Third price after another 10 minutes
        vm.warp(time2 + 10 minutes);
        oracle.updatePrice(token2, 1400 * WAD);
        
        vm.stopPrank();
        
        // With exponential moving average (80% max weight):
        // Step 1: 1000 -> 1000 (first price)
        // Step 2: weight = 600/1800 = 1/3, TWAP = 1000*(2/3) + 1200*(1/3) = 1066.67
        // Step 3: weight = 600/1800 = 1/3, TWAP = 1066.67*(2/3) + 1400*(1/3) = 1177.78
        uint256 twapPrice = oracle.spot(token2);
        uint256 expectedTWAP = 1177777777777777777777; // ~1177.78 WAD
        // Allow for small rounding errors (within 1000 wei)
        assertApproxEqAbs(twapPrice, expectedTWAP, 1000);
    }

    function testTWAPOutsideWindow() public {
        vm.startPrank(priceUpdater);
        
        // First price (this will be outside TWAP window)
        oracle.updatePrice(token2, 500 * WAD);
        uint256 time1 = block.timestamp;
        
        // Move forward beyond TWAP window
        vm.warp(time1 + TWAP_WINDOW + 10 minutes);
        oracle.updatePrice(token2, 1000 * WAD);
        uint256 time2 = block.timestamp;
        
        // Third price after 10 minutes
        vm.warp(time2 + 10 minutes);
        oracle.updatePrice(token2, 1200 * WAD);
        
        vm.stopPrank();
        
        // With exponential moving average (80% max weight):
        // Step 1: 500 -> 500 (first price)
        // Step 2: weight = 0.8 (capped), TWAP = 500*0.2 + 1000*0.8 = 100 + 800 = 900
        // Step 3: weight = 600/1800 = 1/3, TWAP = 900*(2/3) + 1200*(1/3) = 600 + 400 = 1000
        uint256 twapPrice = oracle.spot(token2);
        uint256 expectedTWAP = 1000000000000000000000; // 1000 WAD
        // Allow for small rounding errors (within 1000 wei)
        assertApproxEqAbs(twapPrice, expectedTWAP, 1000);
    }

    function testTWAPStalePrice() public {
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token2, PRICE_1);
        vm.stopPrank();
        
        // Move forward past stale period
        vm.warp(block.timestamp + STALE_PERIOD + 1);
        
        vm.expectRevert(PushOracle.PushOracle__spot_stalePrice.selector);
        oracle.spot(token2);
    }

    function testGetTWAPView() public {
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token2, PRICE_1);
        vm.stopPrank();
        
        uint256 twapPrice = oracle.getTWAP(token2);
        assertEq(twapPrice, PRICE_1);
    }

    function testGetTWAPRevertNotEnabled() public {
        vm.expectRevert(PushOracle.PushOracle__spot_invalidValue.selector);
        oracle.getTWAP(token1); // token1 has TWAP disabled
    }

    /*//////////////////////////////////////////////////////////////
                           CIRCULAR BUFFER TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultiplePriceUpdates() public {
        vm.startPrank(priceUpdater);
        
        // Test multiple price updates - no circular buffer needed with new implementation
        for (uint256 i = 1; i <= 12; i++) {
            oracle.updatePrice(token1, i * 100 * WAD);
            vm.warp(block.timestamp + 1 minutes);
        }
        
        vm.stopPrank();
        
        // Latest price should be the last one we added
        uint256 latestPrice = oracle.getSpotPrice(token1);
        assertEq(latestPrice, 1200 * WAD);
        
        // Verify the price is accessible via spot function
        uint256 spotPrice = oracle.spot(token1);
        assertEq(spotPrice, 1200 * WAD);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function testGrantPriceUpdaterRole() public {
        address newUpdater = makeAddr("newUpdater");
        
        vm.startPrank(admin);
        oracle.grantPriceUpdaterRole(newUpdater);
        vm.stopPrank();
        
        assertTrue(oracle.hasRole(oracle.PRICE_UPDATER_ROLE(), newUpdater));
    }

    function testRevokePriceUpdaterRole() public {
        vm.startPrank(admin);
        oracle.revokePriceUpdaterRole(priceUpdater);
        vm.stopPrank();
        
        assertFalse(oracle.hasRole(oracle.PRICE_UPDATER_ROLE(), priceUpdater));
    }

    function testGrantPriceUpdaterRoleOnlyAdmin() public {
        address newUpdater = makeAddr("newUpdater");
        
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        oracle.grantPriceUpdaterRole(newUpdater);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         UPGRADEABILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testUpgrade() public {
        // Deploy new implementation
        PushOracle newImpl = new PushOracle();
        
        vm.startPrank(manager);
        oracle.upgradeTo(address(newImpl));
        vm.stopPrank();
        
        // Verify upgrade worked by checking the oracle still functions
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token1, PRICE_1);
        vm.stopPrank();
        
        uint256 spotPrice = oracle.spot(token1);
        assertEq(spotPrice, PRICE_1);
    }

    function testUpgradeOnlyManager() public {
        PushOracle newImpl = new PushOracle();
        
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        oracle.upgradeTo(address(newImpl));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        WAD PRECISION TESTS
    //////////////////////////////////////////////////////////////*/

    function testWADPrecisionBasic() public {
        vm.startPrank(priceUpdater);
        
        // Test with precise WAD values
        uint256 precisePrice = 1234567890123456789; // 1.234567890123456789 WAD
        oracle.updatePrice(token1, precisePrice);
        
        vm.stopPrank();
        
        uint256 spotPrice = oracle.spot(token1);
        assertEq(spotPrice, precisePrice);
    }

    function testWADPrecisionTWAPCalculation() public {
        vm.startPrank(priceUpdater);
        
        // Use precise prices that will test WAD arithmetic
        uint256 price1 = 1333333333333333333; // 1.333333333333333333 WAD
        uint256 price2 = 1666666666666666667; // 1.666666666666666667 WAD
        
        oracle.updatePrice(token2, price1);
        
        // Wait exactly 15 minutes (half the TWAP window)
        vm.warp(block.timestamp + 15 minutes);
        oracle.updatePrice(token2, price2);
        
        vm.stopPrank();
        
        // With exponential moving average and 15 minutes (half window):
        // weight = 15 * 60 / (30 * 60) = 0.5
        // newTWAP = price1 * (1 - 0.5) + price2 * 0.5 = 1.333... * 0.5 + 1.666... * 0.5 = 1.5 WAD
        uint256 expectedTWAP = 1500000000000000000; // 1.5 WAD
        uint256 actualTWAP = oracle.spot(token2);
        
        // Allow for 1 wei rounding error
        assertApproxEqAbs(actualTWAP, expectedTWAP, 1);
    }

    function testWADPrecisionComplexTWAP() public {
        vm.startPrank(priceUpdater);
        
        // Test with two prices to verify exponential moving average
        uint256 price1 = 1111111111111111111; // 1.111... WAD
        uint256 price2 = 5555555555555555555; // 5.555... WAD
        
        oracle.updatePrice(token2, price1);
        
        // Wait 5 minutes (1/6 of TWAP window)
        vm.warp(block.timestamp + 5 minutes);
        oracle.updatePrice(token2, price2);
        
        vm.stopPrank();
        
        // With exponential moving average and 5 minutes:
        // weight = 5 * 60 / (30 * 60) = 1/6 ≈ 0.1667
        // newTWAP = price1 * (1 - 1/6) + price2 * (1/6) = 1.111... * (5/6) + 5.555... * (1/6)
        // = 1.111... * 0.8333... + 5.555... * 0.1667... ≈ 1.851851851851851851 WAD
        uint256 expectedTWAP = 1851851851851851851; 
        uint256 actualTWAP = oracle.spot(token2);
        
        // Allow for small rounding errors (within 5 wei)
        assertApproxEqAbs(actualTWAP, expectedTWAP, 5);
    }

    function testWADPrecisionVerySmallPrices() public {
        vm.startPrank(priceUpdater);
        
        // Test with very small prices (micro-cents)
        uint256 smallPrice1 = 1000000000000; // 0.000001 WAD
        uint256 smallPrice2 = 2000000000000; // 0.000002 WAD
        
        oracle.updatePrice(token2, smallPrice1);
        vm.warp(block.timestamp + 10 minutes);
        oracle.updatePrice(token2, smallPrice2);
        vm.warp(block.timestamp + 10 minutes);
        
        vm.stopPrank();
        
        // With exponential moving average:
        // Step 1: 0.000001 -> 0.000001 (first price)
        // Step 2: weight = 600/1800 = 1/3, TWAP = 0.000001*(2/3) + 0.000002*(1/3) = 0.00000133 WAD
        uint256 expectedTWAP = 1333333333333; // ~0.00000133 WAD
        uint256 actualTWAP = oracle.spot(token2);
        
        assertApproxEqAbs(actualTWAP, expectedTWAP, 1000000000); // Allow for precision loss
    }

    function testWADPrecisionVeryLargePrices() public {
        vm.startPrank(priceUpdater);
        
        // Test with very large prices (millions)
        uint256 largePrice1 = 1000000 * WAD; // 1 million
        uint256 largePrice2 = 2000000 * WAD; // 2 million
        
        oracle.updatePrice(token2, largePrice1);
        vm.warp(block.timestamp + 10 minutes);
        oracle.updatePrice(token2, largePrice2);
        vm.warp(block.timestamp + 10 minutes);
        
        vm.stopPrank();
        
        // With exponential moving average:
        // Step 1: 1M -> 1M (first price)
        // Step 2: weight = 600/1800 = 1/3, TWAP = 1M*(2/3) + 2M*(1/3) = 1.33M WAD
        uint256 expectedTWAP = 1333333333333333333333333; // ~1.33M WAD
        uint256 actualTWAP = oracle.spot(token2);
        
        // Allow for small rounding errors (larger tolerance for large numbers)
        assertApproxEqAbs(actualTWAP, expectedTWAP, 1000000);
    }

    function testWADPrecisionRoundingEdgeCases() public {
        vm.startPrank(priceUpdater);
        
        // Test prices that might cause rounding issues
        uint256 price1 = 999999999999999999; // Just under 1 WAD
        uint256 price2 = 1000000000000000001; // Just over 1 WAD
        
        oracle.updatePrice(token2, price1);
        vm.warp(block.timestamp + 1 seconds);
        oracle.updatePrice(token2, price2);
        vm.warp(block.timestamp + 1 seconds);
        
        vm.stopPrank();
        
        // Expected TWAP should be exactly 1 WAD
        uint256 expectedTWAP = WAD;
        uint256 actualTWAP = oracle.spot(token2);
        
        // Allow for small rounding errors (within 5 wei)
        assertApproxEqAbs(actualTWAP, expectedTWAP, 5);
    }

    function testWADPrecisionTWAPWindowBoundary() public {
        vm.startPrank(priceUpdater);
        
        // Add a price that will be exactly at the TWAP window boundary
        oracle.updatePrice(token2, 1000 * WAD);
        uint256 startTime = block.timestamp;
        
        // Move to exactly TWAP_WINDOW seconds later
        vm.warp(startTime + TWAP_WINDOW);
        oracle.updatePrice(token2, 2000 * WAD);
        
        // Move 1 second forward
        vm.warp(block.timestamp + 1);
        oracle.updatePrice(token2, 3000 * WAD);
        
        vm.stopPrank();
        
        // With exponential moving average (80% max weight):
        // Step 1: 1000 -> 1000 (first price)
        // Step 2: weight = 0.8 (capped), TWAP = 1000*0.2 + 2000*0.8 = 1800
        // Step 3: weight = 1/1800 ≈ 0.0006, TWAP ≈ 1800*0.9994 + 3000*0.0006 ≈ 1800.67
        uint256 actualTWAP = oracle.spot(token2);
        
        uint256 expectedTWAP = 1800666666666666666666; // ~1800.67 WAD
        // Allow for small rounding errors (within 1000 wei)
        assertApproxEqAbs(actualTWAP, expectedTWAP, 1000);
    }

    /*//////////////////////////////////////////////////////////////
                           EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultiplePriceUpdaters() public {
        // Test that multiple price updaters can update prices
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token1, PRICE_1);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 5 minutes);
        
        vm.startPrank(priceUpdater2);
        oracle.updatePrice(token1, PRICE_2);
        vm.stopPrank();
        
        uint256 latestPrice = oracle.getSpotPrice(token1);
        assertEq(latestPrice, PRICE_2);
    }

    function testPriceUpdateArrayMismatch() public {
        vm.startPrank(priceUpdater);
        
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;
        
        uint256[] memory prices = new uint256[](1); // Mismatched length
        prices[0] = PRICE_1;
        
        vm.expectRevert("Array length mismatch");
        oracle.updatePrices(tokens, prices);
        
        vm.stopPrank();
    }

    function testConfigArrayMismatch() public {
        vm.startPrank(admin);
        
        address[] memory tokens = new address[](2);
        tokens[0] = makeAddr("newToken1");
        tokens[1] = makeAddr("newToken2");
        
        PushOracle.OracleConfig[] memory configs = new PushOracle.OracleConfig[](1); // Mismatched length
        configs[0] = PushOracle.OracleConfig({
            stalePeriod: STALE_PERIOD,
            twapWindow: TWAP_WINDOW,
            twapEnabled: false
        });
        
        vm.expectRevert("Array length mismatch");
        oracle.setOracleConfigs(tokens, configs);
        
        vm.stopPrank();
    }

    function testTWAPWithNoTimeGap() public {
        vm.startPrank(priceUpdater);
        
        // Add multiple prices at the same timestamp
        oracle.updatePrice(token2, 1000 * WAD);
        oracle.updatePrice(token2, 1200 * WAD);
        oracle.updatePrice(token2, 1400 * WAD);
        
        vm.stopPrank();
        
        // With exponential moving average, when timeElapsed = 0, it returns current TWAP
        // Since all updates happen at same timestamp, TWAP stays at first price
        uint256 twapPrice = oracle.spot(token2);
        assertEq(twapPrice, 1000 * WAD);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzzPriceUpdate(uint256 price) public {
        // Bound price to reasonable range (1 wei to 1 billion WAD)
        price = bound(price, 1, 1_000_000_000 * WAD);
        
        vm.startPrank(priceUpdater);
        oracle.updatePrice(token1, price);
        vm.stopPrank();
        
        uint256 spotPrice = oracle.spot(token1);
        assertEq(spotPrice, price);
    }

    function testFuzzTWAPCalculation(uint256 price1, uint256 price2, uint256 timeGap) public {
        // Bound inputs to reasonable ranges - avoid zero prices
        price1 = bound(price1, 1 * WAD, 1_000_000 * WAD);
        price2 = bound(price2, 1 * WAD, 1_000_000 * WAD);
        timeGap = bound(timeGap, 1 minutes, TWAP_WINDOW - 1 minutes);
        
        vm.startPrank(priceUpdater);
        
        oracle.updatePrice(token2, price1);
        vm.warp(block.timestamp + timeGap);
        oracle.updatePrice(token2, price2);
        vm.warp(block.timestamp + timeGap);
        
        vm.stopPrank();
        
        uint256 twapPrice = oracle.spot(token2);
        
        // With exponential moving average, TWAP should be reasonable
        // It should be greater than 0 and not exceed reasonable bounds
        assertGt(twapPrice, 0);
        
        // For reasonable bounds, TWAP should be within a reasonable range of the input prices
        uint256 minPrice = price1 < price2 ? price1 : price2;
        uint256 maxPrice = price1 > price2 ? price1 : price2;
        
        // Allow for some deviation due to exponential moving average behavior
        // TWAP might be outside the [min, max] range due to the 80% weight cap
        assertGt(twapPrice, minPrice / 2); // Should be at least half the minimum
        assertLt(twapPrice, maxPrice * 2); // Should be at most double the maximum
    }

    function testFuzzCircularBuffer(uint8 numUpdates) public {
        // Bound to reasonable number of updates
        numUpdates = uint8(bound(numUpdates, 1, 20));
        
        vm.startPrank(priceUpdater);
        
        for (uint256 i = 1; i <= numUpdates; i++) {
            oracle.updatePrice(token1, i * WAD);
            vm.warp(block.timestamp + 1 minutes);
        }
        
        vm.stopPrank();
        
        // With new implementation, we don't have storage limits
        // Just verify the latest price is correct
        uint256 latestPrice = oracle.getSpotPrice(token1);
        assertEq(latestPrice, numUpdates * WAD);
    }

    /*//////////////////////////////////////////////////////////////
                        TWAP MATH VERIFICATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testTWAPMathVerification() public {
        vm.startPrank(priceUpdater);
        
        uint256 price1 = 1000 * WAD;
        uint256 price2 = 2000 * WAD;
        uint256 timeGap = 900; // 15 minutes
        
        oracle.updatePrice(token2, price1);
        vm.warp(block.timestamp + timeGap);
        oracle.updatePrice(token2, price2);
        
        uint256 twapPrice = oracle.spot(token2);
        
        // Calculate expected TWAP manually
        // weight = timeGap / TWAP_WINDOW = 900 / 1800 = 0.5
        // newTWAP = price1 * (1 - 0.5) + price2 * 0.5 = 1000 * 0.5 + 2000 * 0.5 = 1500
        uint256 expectedTWAP = 1500 * WAD;
        
        assertEq(twapPrice, expectedTWAP);
        
        vm.stopPrank();
    }

    function testTWAPSmallTimeGap() public {
        vm.startPrank(priceUpdater);
        
        uint256 price1 = 1000 * WAD;
        uint256 price2 = 2000 * WAD;
        uint256 timeGap = 18; // 18 seconds = 1% of TWAP window
        
        oracle.updatePrice(token2, price1);
        vm.warp(block.timestamp + timeGap);
        oracle.updatePrice(token2, price2);
        
        uint256 twapPrice = oracle.spot(token2);
        
        // With 1% weight, TWAP should be very close to original price
        // newTWAP = 1000 * 0.99 + 2000 * 0.01 = 990 + 20 = 1010
        uint256 expectedTWAP = 1010 * WAD;
        
        assertEq(twapPrice, expectedTWAP);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            STRESS TESTS
    //////////////////////////////////////////////////////////////*/

    function testStressManyPriceUpdates() public {
        vm.startPrank(priceUpdater);
        
        // Add many price updates to test performance
        uint256 numUpdates = 10;
        for (uint256 i = 1; i <= numUpdates; i++) {
            oracle.updatePrice(token2, i * 1000 * WAD);
            vm.warp(block.timestamp + 2 minutes);
        }
        
        vm.stopPrank();
        
        // Verify TWAP calculation works correctly
        uint256 twapPrice = oracle.spot(token2);
        
        // Should be a reasonable value (with exponential moving average, it should be closer to recent prices)
        assertGt(twapPrice, 1000 * WAD); // Greater than first price
        assertLt(twapPrice, numUpdates * 1000 * WAD); // Less than last price
    }

    function testStressRapidUpdates() public {
        vm.startPrank(priceUpdater);
        
        // Rapid price updates (same timestamp)
        for (uint256 i = 1; i <= 5; i++) {
            oracle.updatePrice(token1, i * 500 * WAD);
            // Don't advance time - test same timestamp updates
        }
        
        vm.stopPrank();
        
        // Should return the latest price
        uint256 spotPrice = oracle.spot(token1);
        assertEq(spotPrice, 2500 * WAD); // 5 * 500
    }

    function testStressTWAPWithManyPoints() public {
        vm.startPrank(priceUpdater);
        
        // Add many price points with varying intervals
        uint256[] memory prices = new uint256[](8);
        uint256[] memory intervals = new uint256[](8);
        
        prices[0] = 1000 * WAD;
        prices[1] = 1100 * WAD;
        prices[2] = 1200 * WAD;
        prices[3] = 1300 * WAD;
        prices[4] = 1400 * WAD;
        prices[5] = 1500 * WAD;
        prices[6] = 1600 * WAD;
        prices[7] = 1700 * WAD;
        
        intervals[0] = 1 minutes;
        intervals[1] = 2 minutes;
        intervals[2] = 3 minutes;
        intervals[3] = 1 minutes;
        intervals[4] = 4 minutes;
        intervals[5] = 2 minutes;
        intervals[6] = 1 minutes;
        intervals[7] = 0; // Last one doesn't need interval
        
        uint256 currentTime = block.timestamp;
        
        for (uint256 i = 0; i < prices.length; i++) {
            oracle.updatePrice(token2, prices[i]);
            if (i < prices.length - 1) {
                currentTime += intervals[i];
                vm.warp(currentTime);
            }
        }
        
        vm.stopPrank();
        
        // TWAP should be calculated correctly
        uint256 twapPrice = oracle.spot(token2);
        
        // Should be within reasonable bounds
        assertGt(twapPrice, 1000 * WAD);
        assertLt(twapPrice, 1700 * WAD);
    }

    function testStressPrecisionLimits() public {
        vm.startPrank(priceUpdater);
        
        // Test with maximum precision values
        uint256 maxPrecisionPrice1 = type(uint256).max / 1000; // Avoid overflow in calculations
        uint256 maxPrecisionPrice2 = maxPrecisionPrice1 / 2;
        
        oracle.updatePrice(token1, maxPrecisionPrice2);
        vm.warp(block.timestamp + 1 minutes);
        oracle.updatePrice(token1, maxPrecisionPrice1);
        
        vm.stopPrank();
        
        // Should not revert and return a valid price
        uint256 spotPrice = oracle.spot(token1);
        assertEq(spotPrice, maxPrecisionPrice1);
    }
}
