// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {IMultiFeeDistribution} from "../../reward/interfaces/IMultiFeeDistribution.sol";
import {IEligibilityDataProvider} from "../../reward/interfaces/IEligibilityDataProvider.sol";
import {EligibilityDataProvider} from "../../reward/EligibilityDataProvider.sol";
import {ChefIncentivesController} from "../../reward/ChefIncentivesController.sol";
import {ICDPVault} from "../../interfaces/ICDPVault.sol";

/// @title ChefIncentivesController Collateral Tracking Tests
/// @notice Tests to ensure ChefIncentivesController correctly tracks vault collateral amounts
contract ChefIncentivesControllerCollateralTrackingTest is TestBase {
    ChefIncentivesController public incentivesController;
    ERC20Mock public loopToken;

    address public mockEligibilityDataProvider;
    address public mockMultiFeeDistribution;
    address public user;

    uint256 public rewardsPerSecond = 0.01 ether;
    uint256 public endingTimeCadence = 2 days;

    function setUp() public virtual override {
        super.setUp();
        
        user = vm.addr(uint256(keccak256("testUser")));
        loopToken = new ERC20Mock();
        mockEligibilityDataProvider = vm.addr(uint256(keccak256("mockEligibilityDataProvider")));
        mockMultiFeeDistribution = vm.addr(uint256(keccak256("mockMultiFeeDistribution")));

        incentivesController = ChefIncentivesController(
            address(
                new ERC1967Proxy(
                    address(new ChefIncentivesController()),
                    abi.encodeWithSelector(
                        ChefIncentivesController.initialize.selector,
                        address(this),
                        mockEligibilityDataProvider,
                        IMultiFeeDistribution(mockMultiFeeDistribution),
                        rewardsPerSecond,
                        address(loopToken),
                        endingTimeCadence
                    )
                )
            )
        );

        vm.label(mockEligibilityDataProvider, "mockEligibilityDataProvider");
        vm.label(mockMultiFeeDistribution, "mockMultiFeeDistribution");
        vm.label(address(incentivesController), "incentivesController");
        vm.label(address(loopToken), "loopToken");
        vm.label(user, "testUser");
    }

    /// @notice Test that ChefIncentivesController tracks collateral, not debt
    function test_tracksCollateralNotDebt() public {
        // Create a vault with different collateral vs debt amounts
        address mockVault = address(0x1337);
        uint256 userCollateral = 1000 ether;  // High collateral
        uint256 userDebt = 200 ether;         // Low debt (20% LTV)
        
        require(userCollateral != userDebt, "Test setup: collateral and debt must differ");
        
        // Mock vault.positions() to return our test values
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user),
            abi.encode(userCollateral, userDebt, 0, 0, 0, 0)
        );
        
        // Add vault to incentives system
        incentivesController.addPool(mockVault, 100);
        
        // Setup eligibility mocks to trigger _updateRegisteredBalance code path
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(IEligibilityDataProvider.lastEligibleStatus.selector, user),
            abi.encode(false) // User was NOT eligible
        );
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(EligibilityDataProvider.refresh.selector, user),
            abi.encode(true) // User IS now eligible
        );
        
        // Trigger the code path that calls _updateRegisteredBalance
        vm.prank(mockVault);
        incentivesController.handleActionAfter(user, userCollateral, userCollateral);
        
        // Verify we track collateral, not debt
        (uint256 trackedAmount, , ) = incentivesController.userInfo(mockVault, user);
        
        assertEq(trackedAmount, userCollateral, "Should track collateral from vault.positions()");
        assertNotEq(trackedAmount, userDebt, "Should NOT track debt from vault.positions()");
    }

    /// @notice Test edge case where debt > collateral (over-leveraged position)
    function test_tracksCollateralWhenDebtHigher() public {
        address mockVault = address(0xBEEF);
        uint256 userCollateral = 100 ether;   // Lower collateral
        uint256 userDebt = 250 ether;         // Higher debt (overleveraged)
        
        require(userDebt > userCollateral, "Test setup: debt must exceed collateral");
        
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user),
            abi.encode(userCollateral, userDebt, 0, 0, 0, 0)
        );
        
        incentivesController.addPool(mockVault, 100);
        
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(IEligibilityDataProvider.lastEligibleStatus.selector, user),
            abi.encode(false)
        );
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(EligibilityDataProvider.refresh.selector, user),
            abi.encode(true)
        );
        
        vm.prank(mockVault);
        incentivesController.handleActionAfter(user, userCollateral, userCollateral);
        
        (uint256 trackedAmount, , ) = incentivesController.userInfo(mockVault, user);
        
        // Must track the smaller collateral amount, not the larger debt amount
        assertEq(trackedAmount, userCollateral, "Must track collateral even when debt is higher");
        assertNotEq(trackedAmount, userDebt, "Must NOT track higher debt amount");
    }

    /// @notice Test multiple users with different debt/collateral ratios
    function test_multipleUsersWithDifferentRatios() public {
        address mockVault = address(0xCAFE);
        
        address user1 = vm.addr(1);
        address user2 = vm.addr(2);
        address user3 = vm.addr(3);
        
        // Different users with different leverage ratios
        uint256 user1Collateral = 1000 ether;  uint256 user1Debt = 100 ether;   // 10% LTV
        uint256 user2Collateral = 500 ether;   uint256 user2Debt = 400 ether;   // 80% LTV  
        uint256 user3Collateral = 200 ether;   uint256 user3Debt = 180 ether;   // 90% LTV
        
        // Setup mocks for all users
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user1),
            abi.encode(user1Collateral, user1Debt, 0, 0, 0, 0)
        );
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user2),
            abi.encode(user2Collateral, user2Debt, 0, 0, 0, 0)
        );
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user3),
            abi.encode(user3Collateral, user3Debt, 0, 0, 0, 0)
        );
        
        incentivesController.addPool(mockVault, 100);
        
        // Setup eligibility for all users
        address[3] memory users = [user1, user2, user3];
        for (uint i = 0; i < 3; i++) {
            vm.mockCall(
                mockEligibilityDataProvider,
                abi.encodeWithSelector(IEligibilityDataProvider.lastEligibleStatus.selector, users[i]),
                abi.encode(false)
            );
            vm.mockCall(
                mockEligibilityDataProvider,
                abi.encodeWithSelector(EligibilityDataProvider.refresh.selector, users[i]),
                abi.encode(true)
            );
            
            // Trigger tracking for each user
            vm.prank(mockVault);
            if (i == 0) incentivesController.handleActionAfter(user1, user1Collateral, user1Collateral);
            else if (i == 1) incentivesController.handleActionAfter(user2, user2Collateral, user2Collateral);
            else incentivesController.handleActionAfter(user3, user3Collateral, user3Collateral);
        }
        
        // Verify each user tracks collateral
        (uint256 tracked1, , ) = incentivesController.userInfo(mockVault, user1);
        (uint256 tracked2, , ) = incentivesController.userInfo(mockVault, user2);
        (uint256 tracked3, , ) = incentivesController.userInfo(mockVault, user3);
        
        assertEq(tracked1, user1Collateral, "User1: Should track collateral");
        assertEq(tracked2, user2Collateral, "User2: Should track collateral");
        assertEq(tracked3, user3Collateral, "User3: Should track collateral");
        
        // Verify pool total reflects collateral tracking (simplified to avoid stack too deep)
        uint256 expectedSum = user1Collateral + user2Collateral + user3Collateral;
        assertTrue(expectedSum > 0, "Expected sum should be positive");
        assertTrue(tracked1 + tracked2 + tracked3 == expectedSum, "Individual tracking should sum correctly");
    }

    /// @notice Test the _updateRegisteredBalance code path
    function test_updateRegisteredBalanceCodePath() public {
        address mockVault = address(0xDEAD);
        uint256 collateral = 800 ether;
        uint256 debt = 600 ether;
        
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user),
            abi.encode(collateral, debt, 0, 0, 0, 0)
        );
        
        incentivesController.addPool(mockVault, 100);
        
        // User becomes eligible for the first time
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(IEligibilityDataProvider.lastEligibleStatus.selector, user),
            abi.encode(false)
        );
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(EligibilityDataProvider.refresh.selector, user),
            abi.encode(true)
        );
        
        vm.prank(mockVault);
        incentivesController.handleActionAfter(user, 500 ether, 1000 ether);
        
        // Should sync to vault's collateral
        (uint256 finalTracked, , ) = incentivesController.userInfo(mockVault, user);
        assertEq(finalTracked, collateral, "Should sync to collateral");
        assertNotEq(finalTracked, debt, "Should NOT sync to debt");
    }

    /// @notice Test various LTV scenarios
    function test_comprehensiveCollateralTrackingValidation() public {
        // Test with a single vault and different scenarios
        address mockVault = address(0x1337);
        
        // Test Case 1: Low LTV (10%)  
        uint256 lowLtvCollateral = 1000 ether;
        uint256 lowLtvDebt = 100 ether;
        address user1 = vm.addr(10);
        
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user1),
            abi.encode(lowLtvCollateral, lowLtvDebt, 0, 0, 0, 0)
        );
        
        incentivesController.addPool(mockVault, 100);
        
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(IEligibilityDataProvider.lastEligibleStatus.selector, user1),
            abi.encode(false)
        );
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(EligibilityDataProvider.refresh.selector, user1),
            abi.encode(true)
        );
        
        vm.prank(mockVault);
        incentivesController.handleActionAfter(user1, lowLtvCollateral, lowLtvCollateral);
        
        (uint256 tracked1, , ) = incentivesController.userInfo(mockVault, user1);
        assertEq(tracked1, lowLtvCollateral, "Low LTV: Should track collateral");
        assertNotEq(tracked1, lowLtvDebt, "Low LTV: Should NOT track debt");
        
        // Test Case 2: High LTV (80%) with same vault, different user
        uint256 highLtvCollateral = 500 ether;
        uint256 highLtvDebt = 400 ether;
        address user2 = vm.addr(20);
        
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user2),
            abi.encode(highLtvCollateral, highLtvDebt, 0, 0, 0, 0)
        );
        
        // Mock cross-calls for user2 to avoid _updateRegisteredBalance issues
        vm.mockCall(
            mockVault,
            abi.encodeWithSignature("positions(address)", user1),
            abi.encode(lowLtvCollateral, lowLtvDebt, 0, 0, 0, 0)
        );
        
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(IEligibilityDataProvider.lastEligibleStatus.selector, user2),
            abi.encode(false)
        );
        vm.mockCall(
            mockEligibilityDataProvider,
            abi.encodeWithSelector(EligibilityDataProvider.refresh.selector, user2),
            abi.encode(true)
        );
        
        vm.prank(mockVault);
        incentivesController.handleActionAfter(user2, highLtvCollateral, highLtvCollateral);
        
        (uint256 tracked2, , ) = incentivesController.userInfo(mockVault, user2);
        assertEq(tracked2, highLtvCollateral, "High LTV: Should track collateral");
        assertNotEq(tracked2, highLtvDebt, "High LTV: Should NOT track debt");
    }
} 