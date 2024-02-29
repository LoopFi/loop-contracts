// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PSM, CONFIG_ROLE} from "../../PSM.sol";
import {PAUSER_ROLE} from "../../utils/Pause.sol"; 
import {IMinter} from "../../interfaces/IMinter.sol";
import {ICDM} from "../../interfaces/ICDM.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {wmul} from "../../utils/Math.sol";

contract PSMTest is TestBase {

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    PSM psm;

    address me = address(this);

    address collateral;

    function setUp() override(TestBase) public {
        super.setUp();

        MockERC20 mockCollateral = new MockERC20();
        mockCollateral.initialize("MockERC20", "MOCK", 18);
        collateral = address(mockCollateral);

        psm = new PSM( {
            minter_: IMinter(minter),
            cdm_: ICDM(cdm),
            stablecoin_: IERC20(address(stablecoin)),
            collateral_: IERC20(collateral),
            roleAdmin: me,
            configAdmin: me,
            pauseAdmin: me
        });

        cdm.setParameter(address(psm), "debtCeiling", 5_000_000 ether);
        
        vm.label(collateral, "MockCollateral");
    }

    function _deposit(uint256 amount) internal {
        address depositor = address(0x12356789);
        deal(collateral, depositor, amount);
        vm.startPrank(depositor);
        IERC20(collateral).approve(address(psm), amount);
        psm.mint(amount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// ======== Configuration tests ======== ///

    function test_deploy() public {
        assertEq(address(psm.minter()), address(minter));
        assertEq(address(psm.collateral()), address(collateral));
        assertEq(psm.mintFee(), 0);
        assertEq(psm.redeemFee(), 0);
        assertNotEq(address(psm), address(0));
    }

    function test_deploy_permissions(address admin, address configAdmin, address pauseAdmin) public {
        PSM p = new PSM( {
            minter_: IMinter(minter),
            cdm_: ICDM(cdm),
            stablecoin_: IERC20(address(stablecoin)),
            collateral_: IERC20(collateral),
            roleAdmin: admin,
            configAdmin: configAdmin,
            pauseAdmin: pauseAdmin
        });
        cdm.setParameter(address(p), "debtCeiling", 5_000_000 ether);

        assertTrue(p.hasRole(DEFAULT_ADMIN_ROLE , admin));
        assertTrue(p.hasRole(CONFIG_ROLE , configAdmin));
        assertTrue(p.hasRole(PAUSER_ROLE , pauseAdmin));
    }

    function test_setParameter(uint256 mintFee, uint256 redeemFee) public {
        psm.setParameter("mintFee", mintFee);
        assertEq(psm.mintFee(), mintFee);
        psm.setParameter("redeemFee", redeemFee);
        assertEq(psm.redeemFee(), redeemFee);
    }

    function test_setParameter_revertWithUnrecognizedParameter() public {
        vm.expectRevert(PSM.PSM__setParameter_unrecognizedParameter.selector);
        psm.setParameter("unrecognizedParameter", 0);
    }

    function test_setParameter_revertIfNotAuthorized() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        psm.setParameter("mintFee", 0);
    }

    function test_deploy_initialization() public {
        assertEq(address(psm.minter()), address(minter));
        assertEq(address(psm.collateral()), collateral);
        assertEq(psm.mintFee(), 0);
        assertEq(psm.redeemFee(), 0);
        assertEq(psm.collateralConversionFactor(), 1);
    }

    function test_mint() public {
        uint256 mintAmount = 1000 ether;
        uint256 collateralAmount = mintAmount;
        deal(address(collateral), me, collateralAmount);
        IERC20(collateral).approve(address(psm), collateralAmount);
        psm.mint(mintAmount);

        assertEq(stablecoin.balanceOf(me), mintAmount);
        assertEq(IERC20(collateral).balanceOf(me), 0);
    }

    function test_mint_withFee() public {
        uint256 mintAmount = 1000 ether;
        // A 1% mint fee
        uint256 mintFee = 0.01 ether;
        uint256 collateralAmount = mintAmount;

        // Set a mint fee
        psm.setParameter("mintFee", mintFee);

        deal(address(collateral), me, collateralAmount);
        IERC20(collateral).approve(address(psm), collateralAmount);

        psm.mint(mintAmount);

        uint256 feeInStablecoin = wmul(mintAmount, mintFee);

        // The user should receive mintAmount of stablecoins minus the fee
        assertEq(stablecoin.balanceOf(me), mintAmount - feeInStablecoin);
        // The PSM contract should hold the fee in collateral units
        assertEq(IERC20(collateral).balanceOf(address(psm)), collateralAmount);
        // The user's collateral balance should be decreased by the collateralAmount
        assertEq(IERC20(collateral).balanceOf(me), 0);
    }

    function test_mint_revertIfInsufficientFunds() public {
        uint256 mintAmount = 1000 ether;
        // Deal less collateral than needed
        uint256 collateralAmount = mintAmount - 1 ether;
        
        deal(address(collateral), me, collateralAmount);
        IERC20(collateral).approve(address(psm), collateralAmount);

        vm.expectRevert();
        // Should revert due to insufficient collateral
        psm.mint(mintAmount);

        mintAmount = collateralAmount;
        psm.mint(mintAmount);
    }

    function test_mint_revertIfNoAllowance() public {
        uint256 mintAmount = 1000 ether;
        uint256 collateralAmount = mintAmount;
        deal(address(collateral), me, collateralAmount);
        
        vm.expectRevert();
        psm.mint(mintAmount);

        IERC20(collateral).approve(address(psm), collateralAmount);
        psm.mint(mintAmount);
    }

    function test_mint_checkScaledCollateral() public {
        MockERC20 collateral_ = new MockERC20();
        collateral_.initialize("MockERC20", "MOCK", 12);

        PSM p = new PSM( {
            minter_: IMinter(minter),
            cdm_: ICDM(cdm),
            stablecoin_: IERC20(address(stablecoin)),
            collateral_: IERC20(address(collateral_)),
            roleAdmin: me,
            configAdmin: me,
            pauseAdmin: me
        });
        cdm.setParameter(address(p), "debtCeiling", 5_000_000 ether);


        uint256 mintAmount = 1000 ether;
        uint256 collateralAmount = 1000 * 10**12;
        deal(address(collateral_), me, collateralAmount);
        collateral_.approve(address(p), collateralAmount);
        p.mint(mintAmount);

        assertEq(stablecoin.balanceOf(me), mintAmount);
        assertEq(collateral_.balanceOf(me), 0);
    }

    function test_redeem() public {
        uint256 stablecoinAmount = 1000 ether;
        uint256 collateralAmount = stablecoinAmount;
        deal(address(stablecoin), me, stablecoinAmount);

        _deposit(collateralAmount);
        
        assertEq(stablecoin.balanceOf(me), stablecoinAmount);
        assertEq(IERC20(collateral).balanceOf(me), 0);
        assertEq(IERC20(collateral).balanceOf(address(psm)), stablecoinAmount);

        stablecoin.approve(address(psm), stablecoinAmount);
        psm.redeem(stablecoinAmount);
        assertEq(stablecoin.balanceOf(me), 0);
        assertEq(IERC20(collateral).balanceOf(me), collateralAmount);
        assertEq(IERC20(collateral).balanceOf(address(psm)), 0);
    }

    function test_redeem_withFee() public {
        uint256 redeemAmount = 1000 ether;
        uint256 redeemFee = 0.01 ether; // 1% fee
        uint256 collateralAmount = redeemAmount * psm.collateralConversionFactor();

        // Set a redeem fee
        psm.setParameter("redeemFee", redeemFee);

        // The user must have stablecoins to redeem, and the contract must have collateral to give back.
        stablecoin.mint(me, redeemAmount);
        _deposit(collateralAmount);

        stablecoin.approve(address(psm), redeemAmount);
        psm.redeem(redeemAmount);

        uint256 feeInStablecoin = wmul(redeemAmount, redeemFee);
        uint256 feeInCollateral = feeInStablecoin * psm.collateralConversionFactor();

        assertEq(stablecoin.balanceOf(me), 0);
         // User received collateral back minus the fee
        assertEq(IERC20(collateral).balanceOf(me), collateralAmount - feeInCollateral);

        assertEq(IERC20(collateral).balanceOf(address(psm)), feeInCollateral);
    }

    function test_redeem_insufficientStablecoinFunds() public {
        uint256 redeemAmount = 1000 ether; // 1000 stablecoin units
        // The user does not have enough stablecoins to redeem
        stablecoin.mint(me, redeemAmount - 1 ether);

        stablecoin.approve(address(psm), redeemAmount);
        vm.expectRevert();
        psm.redeem(redeemAmount); // Should revert due to insufficient stablecoin funds
    }

    function test_redeem_noStablecoinAllowance() public {
        uint256 redeemAmount = 1000 ether; // 1000 stablecoin units
        uint256 collateralAmount = redeemAmount * psm.collateralConversionFactor();

        // The user has stablecoins but has not approved the PSM to spend them
        stablecoin.mint(me, redeemAmount);
        deal(address(collateral), address(psm), collateralAmount);

        vm.expectRevert();
         // Should revert due to no allowance
        psm.redeem(redeemAmount);
    }

    function test_mintAndRedeem_withFees() public {
        // Set mint and redeem fees
        uint256 mintFee = 0.01 ether; // 1% mint fee
        uint256 redeemFee = 0.01 ether; // 1% redeem fee
        psm.setParameter("mintFee", mintFee);
        psm.setParameter("redeemFee", redeemFee);

        uint256 mintAmount = 1000 ether; // Amount of stablecoins to mint
        uint256 collateralAmount = mintAmount; // Assuming 1:1 collateral to stablecoin ratio

        deal(address(collateral), me, collateralAmount);
        IERC20(collateral).approve(address(psm), collateralAmount);

        // User mints stablecoins with collateral, paying a mint fee
        psm.mint(mintAmount);

        // Calculate fees and expected balances after minting
        uint256 mintFeeInStablecoin = wmul(mintAmount, mintFee);
        uint256 mintedStablecoins = mintAmount - mintFeeInStablecoin;

        assertEq(stablecoin.balanceOf(me), mintedStablecoins);
        assertEq(IERC20(collateral).balanceOf(me), 0);
        assertEq(IERC20(collateral).balanceOf(address(psm)), collateralAmount);

        // User approves PSM to spend stablecoins
        stablecoin.approve(address(psm), mintedStablecoins);
        // User redeems stablecoins for collateral, paying a redeem fee
        psm.redeem(mintedStablecoins);

        // Calculate fees and expected balances after redeeming
        uint256 redeemFeeInStablecoin = wmul(mintedStablecoins, redeemFee);
        uint256 redeemFeeInCollateral = redeemFeeInStablecoin / psm.collateralConversionFactor();
        uint256 collateralRedeemed = (mintedStablecoins / psm.collateralConversionFactor()) - redeemFeeInCollateral;

        assertEq(stablecoin.balanceOf(me), 0);
        assertEq(IERC20(collateral).balanceOf(me), collateralRedeemed);
        assertEq(IERC20(collateral).balanceOf(address(psm)), redeemFeeInCollateral + mintFeeInStablecoin);
    }

    function test_mintRedeemAndCollectFees_withFees() public {
        // Set mint and redeem fees
        uint256 mintFee = 0.01 ether; // 1% mint fee
        uint256 redeemFee = 0.01 ether; // 1% redeem fee
        psm.setParameter("mintFee", mintFee);
        psm.setParameter("redeemFee", redeemFee);

        uint256 mintAmount = 1000 ether;
        uint256 collateralAmount = mintAmount;

        deal(address(collateral), me, collateralAmount);
        IERC20(collateral).approve(address(psm), collateralAmount);

        psm.mint(mintAmount);

        // Calculate expected mint fee in stablecoin and collateral units
        uint256 mintFeeInStablecoin = wmul(mintAmount, mintFee);
        uint256 mintFeeInCollateral = mintFeeInStablecoin / psm.collateralConversionFactor();

        // User redeems the minted stablecoins
        uint256 redeemAmount = mintAmount - mintFeeInStablecoin;
        stablecoin.approve(address(psm), redeemAmount);
        psm.redeem(redeemAmount);

        // Calculate expected redeem fee in stablecoin and collateral units
        uint256 redeemFeeInStablecoin = wmul(redeemAmount, redeemFee);
        uint256 redeemFeeInCollateral = redeemFeeInStablecoin / psm.collateralConversionFactor();

        // Total fees accumulated in the contract should be the sum of mint and redeem fees in collateral units
        uint256 totalFees = mintFeeInCollateral + redeemFeeInCollateral;
        assertEq(psm.collectedFees(), totalFees);

        // Collect the fees
        address feeReceiver = address(0x123);
        uint256 initialFeeReceiverBalance = IERC20(collateral).balanceOf(feeReceiver);

        psm.collectFees(feeReceiver);

        // Validate that the fees are transferred to the fee receiver and the collected fees are reset in the contract
        assertEq(IERC20(collateral).balanceOf(feeReceiver), initialFeeReceiverBalance + totalFees);
        assertEq(psm.collectedFees(), 0);
    }


    function test_collectFees_revertIfNotAuthorized() public {
        // Attempt to collect fees by an unauthorized address
        address unauthorized = address(0x456);
        vm.prank(unauthorized);
        vm.expectRevert();
        psm.collectFees(unauthorized);
    }
}


