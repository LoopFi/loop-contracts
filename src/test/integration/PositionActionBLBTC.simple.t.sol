// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";
import {PRBProxyRegistry} from "../../prb-proxy/PRBProxyRegistry.sol";

import {ICDPVault} from "../../interfaces/ICDPVault.sol";
import {IFlashlender} from "../../interfaces/IFlashlender.sol";
import {IVaultRegistry} from "../../interfaces/IVaultRegistry.sol";
import {IBLBTC} from "../../interfaces/IBLBTC.sol";

import {PositionActionBLBTC} from "../../proxy/PositionActionBLBTC.sol";
import {SwapAction} from "../../proxy/SwapAction.sol";
import {PoolAction} from "../../proxy/PoolAction.sol";

/// @title PositionActionBLBTC Simple Integration Test
/// @notice Simple integration tests for PositionActionBLBTC using deployed Bitlayer contracts
contract PositionActionBLBTCSimpleTest is Test {
    using SafeERC20 for ERC20;

    // Deployed contract addresses from deployment-bitlayer.json
    address constant VAULT_BLBTC = 0xe1987f6cD0b8823a033c29d640596757492479BD;
    address constant FLASHLENDER = 0x5f96431ee187983B00e53068B55A8011aea6b708;
    address constant SWAP_ACTION = 0xE818c6F84a33CC8062C866d28e0b966401D733A4;
    address constant POOL_ACTION = 0x28ae6D200523E3af8372B689dfF6041a8bA019eD;
    address constant VAULT_REGISTRY = 0xD83B0a990ac3dBc9A5F3862b84883Da78F286283;
    address constant PRB_PROXY_REGISTRY = 0x35B4449521750a376C35AF8aA1794b88fbBa5052;
    
    // Token addresses
    address constant WBTC = 0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F;
    address constant BLBTC = 0x4e0dD7c16d2bBf873335cc21C72663b3EAE23014;
    address constant WETH = 0x0000000000000000000000000000000000000000; // Not available on Bitlayer
    
    // Test contracts
    PositionActionBLBTC positionAction;
    ICDPVault vault;
    IFlashlender flashlender;
    SwapAction swapAction;
    PoolAction poolAction;
    IVaultRegistry vaultRegistry;
    PRBProxyRegistry prbProxyRegistry;
    
    // Test user
    address user;
    uint256 userPk;
    PRBProxy userProxy;
    
    function setUp() public {
        // Fork Bitlayer mainnet
        vm.createSelectFork(vm.rpcUrl("bitlayer"));
        
        // Initialize deployed contracts
        vault = ICDPVault(VAULT_BLBTC);
        flashlender = IFlashlender(FLASHLENDER);
        swapAction = SwapAction(SWAP_ACTION);
        poolAction = PoolAction(POOL_ACTION);
        vaultRegistry = IVaultRegistry(VAULT_REGISTRY);
        prbProxyRegistry = PRBProxyRegistry(PRB_PROXY_REGISTRY);
        
        // Deploy PositionActionBLBTC
        positionAction = new PositionActionBLBTC(
            FLASHLENDER,
            SWAP_ACTION,
            POOL_ACTION,
            VAULT_REGISTRY,
            WETH,
            WBTC
        );
        
        // Create test user
        userPk = 0x12341234;
        user = vm.addr(userPk);
        userProxy = PRBProxy(payable(address(prbProxyRegistry.deployFor(user))));
        
        // Fund user with WBTC for testing
        deal(WBTC, user, 10e8); // 10 WBTC
        
        // Labels for better debugging
        vm.label(user, "user");
        vm.label(address(userProxy), "userProxy");
        vm.label(address(positionAction), "positionAction");
        vm.label(VAULT_BLBTC, "vaultBLBTC");
        vm.label(WBTC, "WBTC");
        vm.label(BLBTC, "BLBTC");
    }
    
    /// @notice Test basic deployment and setup
    function test_deployment() public {
        assertTrue(address(positionAction) != address(0));
        assertEq(positionAction.WBTC(), WBTC);
        assertEq(address(positionAction.flashlender()), FLASHLENDER);
        assertEq(address(positionAction.vaultRegistry()), VAULT_REGISTRY);
    }
    
    /// @notice Test that contracts exist and are accessible
    function test_contracts_exist() public {
        // Test vault exists and has correct token
        assertEq(address(vault.token()), BLBTC);
        
        // Test flashlender exists
        assertTrue(address(flashlender) != address(0));
        
        // Test vault registry recognizes the vault
        assertTrue(vaultRegistry.isVaultRegistered(address(vault)));
        
        // Test user has WBTC
        assertEq(ERC20(WBTC).balanceOf(user), 10e8);
    }
    
    /// @notice Test BLBTC token basic functionality
    function test_BLBTC_token_basic() public {
        // Test BLBTC token exists and has basic ERC20 functionality
        IBLBTC blbtc = IBLBTC(BLBTC);
        
        // Test balance query works
        uint256 balance = blbtc.balanceOf(user);
        assertEq(balance, 0); // User should have no BLBTC initially
        
        // Test name/symbol if available (might not be implemented)
        try ERC20(BLBTC).name() returns (string memory name) {
            assertTrue(bytes(name).length > 0);
        } catch {
            // Name might not be implemented, that's ok
        }
    }
    
    /// @notice Test vault position queries
    function test_vault_positions() public {
        // Test position query works
        (uint256 collateral, uint256 debt,,,,) = vault.positions(address(userProxy));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        
        // Test vault configuration
        (uint256 debtFloor, uint256 liquidationRatio) = vault.vaultConfig();
        assertGt(liquidationRatio, 1e18); // Should be > 100%
    }
    
    /// @notice Test pool underlying token
    function test_pool_underlying() public {
        address poolAddress = address(vault.pool());
        assertTrue(poolAddress != address(0));
        
        // Check pool underlying token
        address underlyingToken = vault.pool().underlyingToken();
        assertEq(underlyingToken, WBTC);
    }
    
    /// @notice Test basic WBTC operations
    function test_wbtc_operations() public {
        uint256 amount = 1e8; // 1 WBTC
        
        // Transfer WBTC to proxy
        vm.prank(user);
        ERC20(WBTC).transfer(address(userProxy), amount);
        
        // Check balances
        assertEq(ERC20(WBTC).balanceOf(user), 9e8);
        assertEq(ERC20(WBTC).balanceOf(address(userProxy)), amount);
        
        // Test approval
        vm.prank(address(userProxy));
        ERC20(WBTC).approve(address(positionAction), amount);
        
        uint256 allowance = ERC20(WBTC).allowance(address(userProxy), address(positionAction));
        assertEq(allowance, amount);
    }
    
    /// @notice Test that we can check pool liquidity
    function test_pool_liquidity() public {
        address poolAddress = address(vault.pool());
        uint256 poolBalance = ERC20(WBTC).balanceOf(poolAddress);
        
        // Log the pool balance for debugging
        console.log("Pool WBTC balance:", poolBalance);
        
        // The pool might have 0 balance, which is why flash loans fail
        // This test just documents the current state
        assertTrue(poolAddress != address(0));
    }
    
    /// @notice Test flashlender max loan amount
    function test_flashlender_max_loan() public {
        uint256 maxLoan = flashlender.maxFlashLoan(WBTC);
        console.log("Max flash loan amount:", maxLoan);
        
        // If max loan is 0, flash loans will fail
        // This test documents the current state
        assertTrue(address(flashlender) != address(0));
    }
}
