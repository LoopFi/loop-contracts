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
import {TransferAction, PermitParams, ApprovalType} from "../../proxy/TransferAction.sol";
import {LeverParams, CollateralParams, CreditParams} from "../../proxy/PositionAction.sol";
import {SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {PoolActionParams, Protocol} from "../../proxy/PoolAction.sol";

import {wmul, wdiv, toInt256} from "../../utils/Math.sol";

/// @title PositionActionBLBTC Leverage Integration Test
/// @notice Focused integration tests for leverage operations using deployed Bitlayer contracts
contract PositionActionBLBTCLeverTest is Test {
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
        
        // Fund user with WBTC for testing (18 decimals on Bitlayer)
        deal(WBTC, user, 100e18); // 100 WBTC
        deal(WBTC, address(userProxy), 10e18); // 10 WBTC for proxy
        
        // IMPORTANT: Add liquidity to the pool so flash loans work
        address poolAddress = address(vault.pool());
        deal(WBTC, poolAddress, 1000e18); // 1000 WBTC liquidity (18 decimals on Bitlayer)
        
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
        
        console.log("=== Test Setup Complete ===");
        console.log("User:", user);
        console.log("User Proxy:", address(userProxy));
        console.log("Position Action:", address(positionAction));
        console.log("Vault:", address(vault));
        console.log("User WBTC balance:", ERC20(WBTC).balanceOf(user));
        console.log("Proxy WBTC balance:", ERC20(WBTC).balanceOf(address(userProxy)));
    }
    
    /// @notice Test complete leverage cycle: increase then decrease
    function test_complete_leverage_cycle() public {
        console.log("\n=== Starting Complete Leverage Cycle Test ===");
        
        // Step 1: Increase leverage (loop)
        uint256 upFrontAmount = 0.1e18; // 0.1 WBTC upfront (18 decimals on Bitlayer)
        uint256 borrowAmount = 10e18; // 10 WBTC to borrow via flashloan (above debt floor)
        
        console.log("\n--- Step 1: Increase Leverage ---");
        console.log("Upfront amount:", upFrontAmount);
        console.log("Borrow amount:", borrowAmount);
        
        // Transfer WBTC to user proxy for upfront collateral
        vm.prank(user);
        ERC20(WBTC).transfer(address(userProxy), upFrontAmount);
        
        // Create primary swap params (since we override onFlashLoan, this doesn't matter much)
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
        
        // Create lever params for increase
        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(vault.token()), // BLBTC
            primarySwap: primarySwap,
            auxSwap: emptySwap,
            auxAction: emptyPoolAction
        });
        
        // Record initial state
        uint256 initialUserWBTC = ERC20(WBTC).balanceOf(user);
        uint256 initialProxyWBTC = ERC20(WBTC).balanceOf(address(userProxy));
        uint256 initialProxyBLBTC = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 initialCollateral, uint256 initialDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Initial user WBTC:", initialUserWBTC);
        console.log("Initial proxy WBTC:", initialProxyWBTC);
        console.log("Initial proxy BLBTC:", initialProxyBLBTC);
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
                address(userProxy), // residualRecipient
                emptyPermitParams
            )
        );
        
        // Record state after increase
        uint256 midUserWBTC = ERC20(WBTC).balanceOf(user);
        uint256 midProxyWBTC = ERC20(WBTC).balanceOf(address(userProxy));
        uint256 midProxyBLBTC = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 midCollateral, uint256 midDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("After increase - user WBTC:", midUserWBTC);
        console.log("After increase - proxy WBTC:", midProxyWBTC);
        console.log("After increase - proxy BLBTC:", midProxyBLBTC);
        console.log("After increase - collateral:", midCollateral);
        console.log("After increase - debt:", midDebt);
        
        // Verify increase worked
        assertGt(midCollateral, initialCollateral, "Collateral should increase");
        assertGt(midDebt, initialDebt, "Debt should increase");
        assertEq(midUserWBTC, initialUserWBTC, "User WBTC should be unchanged (proxy paid)");
        assertLt(midProxyWBTC, initialProxyWBTC, "Proxy WBTC should decrease");
        
        console.log("SUCCESS: Increase leverage successful");
        
        // Step 2: Decrease leverage (unloop)
        console.log("\n--- Step 2: Decrease Leverage ---");
        
        // Decrease by 50% of current position
        uint256 subCollateral = midCollateral / 2;
        uint256 expectedRepayAmount = midDebt / 2;
        
        console.log("Collateral to remove:", subCollateral);
        console.log("Expected repay amount:", expectedRepayAmount);
        
        // Create primary swap for decrease (BLBTC -> WBTC conversion handled internally)
        SwapParams memory decreasePrimarySwap = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: BLBTC, // The collateral token that will be withdrawn and converted
            amount: expectedRepayAmount, // This will be overridden by the actual withdrawn amount
            limit: expectedRepayAmount, // Expected WBTC output
            recipient: address(positionAction),
            residualRecipient: address(positionAction),
            deadline: block.timestamp + 1 hours,
            args: ""
        });
        
        // Create lever params for decrease
        LeverParams memory decreaseLeverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(vault.token()), // BLBTC
            primarySwap: decreasePrimarySwap,
            auxSwap: emptySwap,
            auxAction: emptyPoolAction
        });
        
        // Execute decrease lever
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector,
                decreaseLeverParams,
                subCollateral,
                user // residualRecipient (receives leftover WBTC)
            )
        );
        
        // Record final state
        uint256 finalUserWBTC = ERC20(WBTC).balanceOf(user);
        uint256 finalProxyWBTC = ERC20(WBTC).balanceOf(address(userProxy));
        uint256 finalProxyBLBTC = ERC20(BLBTC).balanceOf(address(userProxy));
        (uint256 finalCollateral, uint256 finalDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Final user WBTC:", finalUserWBTC);
        console.log("Final proxy WBTC:", finalProxyWBTC);
        console.log("Final proxy BLBTC:", finalProxyBLBTC);
        console.log("Final collateral:", finalCollateral);
        console.log("Final debt:", finalDebt);
        
        // Verify decrease worked
        assertLt(finalCollateral, midCollateral, "Collateral should decrease");
        assertLt(finalDebt, midDebt, "Debt should decrease");
        assertGt(finalUserWBTC, midUserWBTC, "User should receive WBTC from unwinding");
        
        console.log("SUCCESS: Decrease leverage successful");
        
        console.log("\n=== Cycle Summary ===");
        console.log("Remaining collateral:", finalCollateral);
        console.log("Remaining debt:", finalDebt);
        console.log("SUCCESS: Complete leverage cycle test passed");
    }
    
    /// @notice Test edge case: full position closure
    function test_full_position_closure() public {
        console.log("\n=== Starting Full Position Closure Test ===");
        
        // First create a position
        _createLeveragedPosition();
        
        // Get current position
        (uint256 currentCollateral, uint256 currentDebt,,,,) = vault.positions(address(userProxy));
        
        console.log("Position to close - Collateral:", currentCollateral);
        console.log("Position to close - Debt:", currentDebt);
        
        // Close entire position (BLBTC -> WBTC conversion handled internally)
        SwapParams memory primarySwap = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: BLBTC, // The collateral token that will be withdrawn and converted
            amount: currentDebt, // This will be overridden by the actual withdrawn amount
            limit: currentDebt, // Expected WBTC output to repay debt
            recipient: address(positionAction),
            residualRecipient: address(positionAction),
            deadline: block.timestamp + 1 hours,
            args: ""
        });
        
        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(vault.token()),
            primarySwap: primarySwap,
            auxSwap: emptySwap,
            auxAction: emptyPoolAction
        });
        
        uint256 initialUserWBTC = ERC20(WBTC).balanceOf(user);
        
        // Execute full closure
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector,
                leverParams,
                currentCollateral, // Remove all collateral
                user
            )
        );
        
        // Verify position is closed
        (uint256 finalCollateral, uint256 finalDebt,,,,) = vault.positions(address(userProxy));
        uint256 finalUserWBTC = ERC20(WBTC).balanceOf(user);
        
        console.log("Final collateral:", finalCollateral);
        console.log("Final debt:", finalDebt);
        console.log("Final user WBTC:", finalUserWBTC);
        
        assertEq(finalCollateral, 0, "Collateral should be zero");
        assertEq(finalDebt, 0, "Debt should be zero");
        assertGt(finalUserWBTC, initialUserWBTC, "User should receive WBTC");
        
        console.log("SUCCESS: Full position closure successful");
    }
    
    /// @notice Helper function to create a leveraged position
    function _createLeveragedPosition() internal {
        uint256 upFrontAmount = 0.1e18; // 0.1 WBTC (18 decimals on Bitlayer)
        uint256 borrowAmount = 10e18; // 10 WBTC (above debt floor)
        
        // Transfer WBTC to proxy
        vm.prank(user);
        ERC20(WBTC).transfer(address(userProxy), upFrontAmount);
        
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
        
        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(vault.token()),
            primarySwap: primarySwap,
            auxSwap: emptySwap,
            auxAction: emptyPoolAction
        });
        
        vm.prank(user);
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                WBTC,
                upFrontAmount,
                address(userProxy), // residualRecipient
                emptyPermitParams
            )
        );
    }
    
    /// @notice Test error conditions
    function test_error_conditions() public {
        console.log("\n=== Testing Error Conditions ===");
        
        // Test 1: Try to increase lever without sufficient upfront amount
        console.log("Testing insufficient upfront amount...");
        
        SwapParams memory primarySwap = SwapParams({
            swapProtocol: SwapProtocol.BALANCER,
            swapType: SwapType.EXACT_IN,
            assetIn: WBTC,
            amount: 0.1e18,
            limit: 0.1e18,
            recipient: address(positionAction),
            residualRecipient: address(positionAction),
            deadline: block.timestamp + 1 hours,
            args: ""
        });
        
        LeverParams memory leverParams = LeverParams({
            position: address(userProxy),
            vault: address(vault),
            collateralToken: address(vault.token()),
            primarySwap: primarySwap,
            auxSwap: emptySwap,
            auxAction: emptyPoolAction
        });
        
        // This should fail because proxy has no WBTC
        vm.prank(user);
        vm.expectRevert();
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.increaseLever.selector,
                leverParams,
                WBTC,
                100e18, // More than proxy has
                address(userProxy),
                emptyPermitParams
            )
        );
        
        console.log("SUCCESS: Insufficient upfront amount test passed");
        
        // Test 2: Try to decrease lever on empty position
        console.log("Testing decrease on empty position...");
        
        vm.prank(user);
        vm.expectRevert();
        userProxy.execute(
            address(positionAction),
            abi.encodeWithSelector(
                positionAction.decreaseLever.selector,
                leverParams,
                1e18, // Try to remove collateral that doesn't exist
                user
            )
        );
        
        console.log("SUCCESS: Empty position decrease test passed");
    }
}
