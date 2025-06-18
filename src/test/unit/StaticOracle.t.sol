// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TestBase} from "../TestBase.sol";
import {StaticOracle} from "../../oracle/StaticOracle.sol";
import {IOracle} from "../../interfaces/IOracle.sol";

contract StaticOracleTest is TestBase {
    StaticOracle internal staticOracle;
    address internal randomToken;

    function setUp() public override {
        super.setUp();

        // Deploy the implementation
        StaticOracle staticOracleImpl = new StaticOracle();
        
        // Deploy the proxy with the implementation
        staticOracle = StaticOracle(
            address(
                new ERC1967Proxy(
                    address(staticOracleImpl),
                    abi.encodeWithSelector(StaticOracle.initialize.selector, address(this), address(this))
                )
            )
        );
        
        // Create a random token address for testing
        randomToken = vm.addr(1);
    }

    function test_deployOracle() public {
        assertTrue(address(staticOracle) != address(0));
    }

    function test_spotReturnsStaticPrice() public {
        uint256 price = staticOracle.spot(randomToken);
        assertEq(price, 1e18);
    }
    
    function test_spotReturnsStaticPriceForAnyToken() public {
        address token1 = vm.addr(2);
        address token2 = vm.addr(3);
        
        uint256 price1 = staticOracle.spot(token1);
        uint256 price2 = staticOracle.spot(token2);
        uint256 price3 = staticOracle.spot(address(0));
        
        assertEq(price1, 1e18);
        assertEq(price2, 1e18);
        assertEq(price3, 1e18);
    }
    
    function test_getStatusAlwaysTrue() public {
        bool status = staticOracle.getStatus(randomToken);
        assertTrue(status);
    }
    
    function test_getStatusAlwaysTrueForAnyToken() public {
        address token1 = vm.addr(2);
        address token2 = vm.addr(3);
        
        bool status1 = staticOracle.getStatus(token1);
        bool status2 = staticOracle.getStatus(token2);
        bool status3 = staticOracle.getStatus(address(0));
        
        assertTrue(status1);
        assertTrue(status2);
        assertTrue(status3);
    }
} 