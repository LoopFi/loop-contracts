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
import {IBLBTC, IBPool} from "../../interfaces/IBLBTC.sol";

import {PositionActionBLBTC} from "../../proxy/PositionActionBLBTC.sol";
import {SwapAction} from "../../proxy/SwapAction.sol";
import {PoolAction} from "../../proxy/PoolAction.sol";
import {TransferAction, PermitParams, ApprovalType} from "../../proxy/TransferAction.sol";
import {LeverParams, CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PoolActionParams, Protocol} from "../../proxy/PoolAction.sol";

import {wmul, wdiv, toInt256} from "../../utils/Math.sol";

/// @title PositionActionBLBTC Integration Test
/// @notice Integration tests for PositionActionBLBTC using deployed Bitlayer contracts
contract PositionActionBLBTCTest is Test {
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
    
    // Common test parameters
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    PoolActionParams emptyPoolAction;
    
    // WBTC whale address for funding tests
    address constant WBTC_WHALE = 0x3f5CE5FBFe3E9af3971dD833D26bA9b5C936f0bE; // Binance hot wallet
    
    function setUp() public {
        // Fork Bitlayer mainnet
        vm.createSelectFork(vm.rpcUrl("bitlayer")); // Use configured bitlayer RPC
        
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
        _fundUserWithWBTC(user, 100e18); // 100 WBTC (18 decimals on Bitlayer)00w
        
        // IMPORTANT: Add liquidity to the pool so flash loans work
        address poolAddress = address(vault.pool());
        deal(WBTC, poolAddress, 1000e18); // 1000 WBTC liquidity (18 decimals on Bitlayer)
        
        // Mock oracle price to avoid stale price errors
        _mockOraclePrice();
        
        // Setup empty parameters
        emptyPermitParams = PermitParams({
            approvalType: ApprovalType.STANDARD,
            approvalAmount: 0,
            nonce: 0,
            deadline: 0,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        
        emptySwap = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: address(0),
            amount: 0,
            limit: 0,
            recipient: address(0),
            residualRecipient: address(0),
            deadline: block.timestamp + 1 hours,
            args: ""
        });
        
        emptyPoolAction = PoolActionParams({
            protocol: Protocol.BALANCER,
            args: "",
            minOut: 0,
            recipient: address(0)
        });
        
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
    
    /// @notice Test increasing leverage (looping) with BLBTC
    function test_increaseLever_BLBTC() public {
        uint256 upFrontAmount = 0.1e18; // 0.1 WBTC (18 decimals on Bitlayer)
        uint256 borrowAmount = 10e18; // 10 WBTC to borrow (debt floor is 1e15, so this should be enough)
        
        // Get initial balances BEFORE any transfers
        uint256 initialWBTCBalance = ERC20(WBTC).balanceOf(user);
        uint256 initialBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 initialCollateral, uint256 initialDebt,,,,) = vault.positions(address(userProxy));
        
        // Transfer WBTC to user proxy for upfront collateral
        vm.prank(user);
        ERC20(WBTC).transfer(address(userProxy), upFrontAmount);
        
        // Since we override onFlashLoan, the swap params don't matter much
        // But we still need to provide valid params for the base contract validation
        SwapParams memory primarySwap = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: WBTC, // Flash loan asset (required by base contract validation)
            amount: borrowAmount, // Flash loan amount
            limit: borrowAmount, // Expected output (same as input)
            recipient: address(positionAction),
            residualRecipient: address(positionAction),
            deadline: block.timestamp + 1 hours,
            args: "" // Not used since we override onFlashLoan
        });
        
        // Create lever params
        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(vault.token()), // BLBTC
            primarySwap: primarySwap,
            auxSwap: emptySwap, // No aux swap needed
            auxAction: emptyPoolAction
        });
        
        console.log("Initial WBTC balance:", initialWBTCBalance);
        console.log("Initial BLBTC balance:", initialBLBTCBalance);
        console.log("Initial collateral:", initialCollateral);
        console.log("Initial debt:", initialDebt);
        
        // Execute increase lever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                WBTC, // upFrontToken
                upFrontAmount,
                address(userProxy), // collateralizer
                emptyPermitParams
            )
        );
        
        // Check final balances
        uint256 finalWBTCBalance = ERC20(WBTC).balanceOf(user);
        uint256 finalBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 finalCollateral, uint256 finalDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Final WBTC balance:", finalWBTCBalance);
        console.log("Final BLBTC balance:", finalBLBTCBalance);
        console.log("Final collateral:", finalCollateral);
        console.log("Final debt:", finalDebt);
        
        // Assertions
        assertGt(finalCollateral, initialCollateral, "Collateral should increase");
        assertGt(finalDebt, initialDebt, "Debt should increase");
        assertEq(finalWBTCBalance, initialWBTCBalance - upFrontAmount, "User WBTC should decrease by upfront amount");
    }
    
    /// @notice Test decreasing leverage (unlooping) with BLBTC
    function test_decreaseLever_BLBTC() public {
        // First, create a leveraged position
        test_increaseLever_BLBTC();
        
        // Get current position state
        (uint256 currentCollateral, uint256 currentDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Current collateral before decrease:", currentCollateral);
        console.log("Current debt before decrease:", currentDebt);
        
        // Decrease leverage by 50%
        uint256 subCollateral = currentCollateral / 2;
        uint256 repayAmount = currentDebt / 2;
        
        // Create swap params for BLBTC -> WBTC conversion (handled internally)
        SwapParams memory primarySwap = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: BLBTC, // The collateral token that will be withdrawn and converted
            amount: repayAmount, // This will be overridden by the actual withdrawn amount
            limit: repayAmount, // Expected WBTC output
            recipient: address(positionAction),
            residualRecipient: address(positionAction),
            deadline: block.timestamp + 1 hours,
            args: ""
        });
        
        // Create lever params for decrease
        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(vault.token()), // BLBTC
            primarySwap: primarySwap,
            auxSwap: emptySwap, // No aux swap needed
            auxAction: emptyPoolAction
        });
        
        // Get initial balances
        uint256 initialWBTCBalance = ERC20(WBTC).balanceOf(user);
        uint256 initialBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        
        console.log("Initial WBTC balance before decrease:", initialWBTCBalance);
        console.log("Initial BLBTC balance before decrease:", initialBLBTCBalance);
        
        // Execute decrease lever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector,
                leverParams,
                subCollateral,
                user // residualRecipient
            )
        );
        
        // Check final balances
        uint256 finalWBTCBalance = ERC20(WBTC).balanceOf(user);
        uint256 finalBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 finalCollateral, uint256 finalDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Final WBTC balance after decrease:", finalWBTCBalance);
        console.log("Final BLBTC balance after decrease:", finalBLBTCBalance);
        console.log("Final collateral after decrease:", finalCollateral);
        console.log("Final debt after decrease:", finalDebt);
        
        // Assertions
        assertLt(finalCollateral, currentCollateral, "Collateral should decrease");
        assertLt(finalDebt, currentDebt, "Debt should decrease");
        assertGt(finalWBTCBalance, initialWBTCBalance, "User should receive WBTC from unwinding");
    }
    
    /// @notice Test deposit WBTC and convert to BLBTC
    function test_deposit_WBTC_to_BLBTC() public {
        uint256 depositAmount = 0.05e8; // 0.05 WBTC
        
        // Transfer WBTC to user proxy
        vm.prank(user);
        ERC20(WBTC).transfer(address(userProxy), depositAmount);
        
        // Create collateral params - targetToken is WBTC (what user is providing)
        // The position action will handle converting WBTC to BLBTC internally
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: WBTC, // This is what the user is providing
            amount: depositAmount,
            collateralizer: address(userProxy),
            auxSwap: emptySwap,
            minAmountOut: 0
        });
        
        // Get initial balances
        uint256 initialWBTCBalance = ERC20(WBTC).balanceOf(address(userProxy));
        uint256 initialBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 initialCollateral, uint256 initialDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Initial WBTC balance:", initialWBTCBalance);
        console.log("Initial BLBTC balance:", initialBLBTCBalance);
        console.log("Initial collateral:", initialCollateral);
        
        // Execute deposit
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.deposit.selector,
                address(userProxy), // position
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        
        // Check final balances
        uint256 finalWBTCBalance = ERC20(WBTC).balanceOf(address(userProxy));
        uint256 finalBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 finalCollateral, uint256 finalDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Final WBTC balance:", finalWBTCBalance);
        console.log("Final BLBTC balance:", finalBLBTCBalance);
        console.log("Final collateral:", finalCollateral);
        
        // Assertions
        assertLt(finalWBTCBalance, initialWBTCBalance, "WBTC balance should decrease");
        assertGt(finalCollateral, initialCollateral, "Collateral should increase");
        assertEq(finalDebt, initialDebt, "Debt should remain unchanged");
    }
    
    /// @notice Test withdraw BLBTC and convert to WBTC
    function test_withdraw_BLBTC_to_WBTC() public {
        // First deposit some collateral
        test_deposit_WBTC_to_BLBTC();
        
        // Get current position state
        (uint256 currentCollateral,,,,,) = vault.positions(address(userProxy));
        uint256 withdrawAmount = currentCollateral / 2; // Withdraw 50%
        
        // Create collateral params
        CollateralParams memory collateralParams = CollateralParams({
            targetToken: WBTC,
            amount: withdrawAmount,
            collateralizer: user,
            auxSwap: emptySwap,
            minAmountOut: 0
        });
        
        // Get initial balances
        uint256 initialWBTCBalance = ERC20(WBTC).balanceOf(user);
        uint256 initialBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 initialCollateral,,,,,) = vault.positions(address(userProxy));
        
        console.log("Initial WBTC balance:", initialWBTCBalance);
        console.log("Initial BLBTC balance:", initialBLBTCBalance);
        console.log("Initial collateral:", initialCollateral);
        
        // Execute withdraw
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.withdraw.selector,
                address(userProxy), // position
                address(vault),
                collateralParams,
                emptyPermitParams
            )
        );
        
        // Check final balances
        uint256 finalWBTCBalance = ERC20(WBTC).balanceOf(user);
        uint256 finalBLBTCBalance = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 finalCollateral,,,,,) = vault.positions(address(userProxy));
        
        console.log("Final WBTC balance:", finalWBTCBalance);
        console.log("Final BLBTC balance:", finalBLBTCBalance);
        console.log("Final collateral:", finalCollateral);
        
        // Assertions
        assertGt(finalWBTCBalance, initialWBTCBalance, "User WBTC balance should increase");
        assertLt(finalCollateral, initialCollateral, "Collateral should decrease");
    }
    
    /// @notice Helper function to fund user with WBTC
    function _fundUserWithWBTC(address recipient, uint256 amount) internal {
        // Try to find a WBTC holder on Bitlayer or deal tokens directly
        deal(WBTC, recipient, amount);
    }
    
    /// @notice Mock oracle price to avoid stale price errors
    function _mockOraclePrice() internal {
        // Mock the oracle to return a valid price (1 WBTC = 1 BLBTC for simplicity)
        address oracle = address(vault.oracle());
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("spot(address)", BLBTC),
            abi.encode(1e18) // 1:1 ratio
        );
    }
    
    /// @notice Test that verifies BLBTC contract basic properties
    function test_BLBTC_basic_properties() public {
        // Test basic ERC20 properties first
        ERC20 blbtc = ERC20(BLBTC);
        
        console.log("BLBTC name:", blbtc.name());
        console.log("BLBTC symbol:", blbtc.symbol());
        console.log("BLBTC decimals:", blbtc.decimals());
        console.log("BLBTC total supply:", blbtc.totalSupply());
        
        // Test if we can call basic functions without reverting
        assertTrue(bytes(blbtc.name()).length > 0, "Should have a name");
        assertTrue(bytes(blbtc.symbol()).length > 0, "Should have a symbol");
        assertGt(blbtc.totalSupply(), 0, "Should have total supply");
        
        // Test the pool interface
        IBLBTC blbtcPool = IBLBTC(BLBTC);
        IBPool bPool = blbtcPool.bPool();
        
        console.log("BPool address:", address(bPool));
        assertTrue(address(bPool) != address(0), "BPool should exist");
        
        // Check vault configuration
        (uint256 debtFloor, uint256 liquidationRatio) = vault.vaultConfig();
        console.log("Vault debt floor:", debtFloor);
        console.log("Vault liquidation ratio:", liquidationRatio);
        
        // CRITICAL: Check the pool's underlying token and its decimals
        address poolUnderlying = address(vault.poolUnderlying());
        uint256 poolUnderlyingScale = vault.poolUnderlyingScale();
        console.log("Pool underlying token:", poolUnderlying);
        console.log("Pool underlying scale:", poolUnderlyingScale);
        console.log("WBTC address:", WBTC);
        console.log("WBTC decimals:", ERC20(WBTC).decimals());
        
        if (poolUnderlying != address(0)) {
            console.log("Pool underlying decimals:", ERC20(poolUnderlying).decimals());
        }
        
        // Test getting current tokens
        address[] memory tokens = bPool.getCurrentTokens();
        console.log("Pool has", tokens.length, "tokens");
        assertTrue(tokens.length > 0, "Pool should have tokens");
        
        // Check if WBTC is in the pool
        bool wbtcFound = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("Token", i, ":", tokens[i]);
            if (tokens[i] == WBTC) {
                wbtcFound = true;
                uint256 balance = bPool.getBalance(WBTC);
                console.log("WBTC balance in pool:", balance);
            }
        }
        assertTrue(wbtcFound, "WBTC should be in the BLBTC pool");
    }
}
