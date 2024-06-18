// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {
    TestBase,
    ERC20PresetMinterPauser,
    PoolV3,
    IERC20,
    TransparentUpgradeableProxy,
    ProxyAdmin,
    IPoolV3
} from "../TestBase.sol";

import {WAD} from "../../utils/Math.sol";

import {IFlashlender, FlashLoanReceiverBase, IERC3156FlashBorrower} from "../../interfaces/IFlashlender.sol";
import {IPermission} from "../../interfaces/IPermission.sol";

import {CDPVault} from "../../CDPVault.sol";
import {Flashlender} from "../../Flashlender.sol";

abstract contract TestReceiver is FlashLoanReceiverBase {

    constructor(address flash) FlashLoanReceiverBase(flash) {
        // IPoolV3 pool = IFlashlender(flash).pool();
    }

    function _mintStablecoinFee(uint256 amount) internal {
        if (amount > 0) {
            ERC20PresetMinterPauser token = ERC20PresetMinterPauser(address(flashlender.underlyingToken()));
            token.mint(address(this), amount);
        }
    }

    function _mintCreditFee(uint256 fee) internal {
        if (fee > 0) {
            IPoolV3 pool = IFlashlender(flashlender).pool();
            ERC20PresetMinterPauser token = ERC20PresetMinterPauser(address(flashlender.underlyingToken()));
            token.mint(address(pool), fee);
            pool.repayCreditAccount(fee, fee, 0);
        }
    }
}


contract TestImmediatePaybackReceiver is TestReceiver {

    constructor(address flash) TestReceiver(flash) {
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        _mintStablecoinFee(fee_);
        // Just pay back the original amount
        approvePayback(amount_ + fee_);

        return CALLBACK_SUCCESS;
    }
}

contract TestReentrancyReceiver is TestReceiver {
    TestImmediatePaybackReceiver public immediatePaybackReceiver;

    constructor(address flash) TestReceiver(flash) {
        immediatePaybackReceiver = new TestImmediatePaybackReceiver(flash);
    }

    function onFlashLoan(
        address,
        address token_,
        uint256 amount_,
        uint256 fee_,
        bytes calldata data_
    ) external override returns (bytes32) {
        flashlender.flashLoan(immediatePaybackReceiver, token_, amount_ + fee_, data_);

        approvePayback(amount_ + fee_);

        return CALLBACK_SUCCESS;
    }
}

contract TestDEXTradeReceiver is TestReceiver {
    IPoolV3 public pool;
    ERC20PresetMinterPauser public underlyingToken;
    ERC20PresetMinterPauser public token;
    CDPVault public vaultA;

    constructor(
        address flash,
        address token_,
        address vaultA_
    ) TestReceiver(flash) {
        pool = IFlashlender(flash).pool();
        underlyingToken = ERC20PresetMinterPauser(address(IFlashlender(flash).underlyingToken()));
        token = ERC20PresetMinterPauser(token_);
        vaultA = CDPVault(vaultA_);
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        address me = address(this);
        uint256 totalDebt = amount_ + fee_;
        uint256 tokenAmount = totalDebt * 3;

        // Perform a "trade"
        underlyingToken.transfer(address(0x1), amount_);
        token.mint(me, tokenAmount);

        // Create a position and borrow underlying tokens
        token.approve(address(vaultA), type(uint256).max);
        vaultA.modifyCollateralAndDebt(
            me,
            me,
            me,
            int256(tokenAmount),
            int256(totalDebt)
        );

        approvePayback(amount_ + fee_);

        return CALLBACK_SUCCESS;
    }
}

contract TestBadReturn is TestReceiver {
    bytes32 public constant BAD_HASH = keccak256("my bad hash");

    constructor(address flash) TestReceiver(flash) {}

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256 fee_,
        bytes calldata
    ) external override returns (bytes32) {
        _mintStablecoinFee(fee_);
        approvePayback(amount_ + fee_);

        return BAD_HASH;
    }
}

contract TestNoFeePaybackReceiver is TestReceiver {

    constructor(address flash) TestReceiver(flash) {}

    function onFlashLoan(
        address,
        address,
        uint256 amount_,
        uint256,
        bytes calldata
    ) external override returns (bytes32) {
        // Just pay back the original amount w/o fee
        approvePayback(amount_);
        return CALLBACK_SUCCESS;
    }
}

contract TestNoCallbacks {}

contract FlashlenderTest is TestBase {
    address public me;

    CDPVault public vault;

    TestImmediatePaybackReceiver public immediatePaybackReceiver;
    TestImmediatePaybackReceiver public immediatePaybackReceiverOne; // 1% fee
    TestImmediatePaybackReceiver public immediatePaybackReceiverFive; // 5% fee

    TestNoFeePaybackReceiver public noFeePaybackReceiver; // 1% fee

    TestReentrancyReceiver public reentrancyReceiver;
    TestDEXTradeReceiver public dexTradeReceiver;
    TestBadReturn public badReturn;
    TestNoCallbacks public noCallbacks;

    Flashlender flashlenderOne; // w/ 1% fee
    Flashlender flashlenderFive; // w/ 5% fee

    ERC20PresetMinterPauser public underlyingToken;

    // override cdm to manually mint fees and flashlender with fees
    function createCore() internal override {
        super.createCore();
        flashlenderOne = new Flashlender(IPoolV3(address(liquidityPool)), 1e16); // 1% fee
        flashlenderFive = new Flashlender(IPoolV3(address(liquidityPool)), 5e16); // 5% fee
        setGlobalDebtCeiling(5_000_000 ether);

        liquidityPool.setCreditManagerDebtLimit(address(flashlenderOne), type(uint256).max);
        liquidityPool.setCreditManagerDebtLimit(address(flashlenderFive), type(uint256).max);
    }

    function setUp() public override {
        super.setUp();
        me = address(this);
        underlyingToken = mockWETH;

        // set up vault
        vault = createCDPVault(
            token,
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether // liquidation discount
        );

        // deploy receivers
        immediatePaybackReceiver = new TestImmediatePaybackReceiver(address(flashlender));
        immediatePaybackReceiverOne = new TestImmediatePaybackReceiver(address(flashlenderOne));
        immediatePaybackReceiverFive = new TestImmediatePaybackReceiver(address(flashlenderFive));

        bytes32 minterRole = keccak256("MINTER_ROLE");
        underlyingToken.grantRole(minterRole, address(immediatePaybackReceiver));
        underlyingToken.grantRole(minterRole, address(immediatePaybackReceiverOne));
        underlyingToken.grantRole(minterRole, address(immediatePaybackReceiverFive));

        noFeePaybackReceiver = new TestNoFeePaybackReceiver(address(flashlenderOne));

        reentrancyReceiver = new TestReentrancyReceiver(address(flashlender));
        dexTradeReceiver = new TestDEXTradeReceiver(
            address(flashlender),
            address(token),
            address(vault)
        );
        badReturn = new TestBadReturn(address(flashlender));
        noCallbacks = new TestNoCallbacks();
    }

    function test_deploy() public {
        assertNotEq(address(flashlender), address(0));
        assertNotEq(address(flashlenderOne), address(0));
        assertNotEq(address(flashlenderFive), address(0));
    }

    function test_flashloan_payback_zero_fees() public {
        vm.expectRevert("ERC20: insufficient allowance"); // expect revert because not enough allowance to cover fees
        flashlender.flashLoan(noFeePaybackReceiver, address(underlyingToken), 10 ether, "");
    }

    function test_mint_payback_zero_fees() public {
        uint256 flashLoanAmount = 10 ether;
        uint256 expectedFee = flashlender.flashFee(address(underlyingToken), flashLoanAmount);

        // assert zero fee
        assertEq(expectedFee, 0);

        flashlender.flashLoan(immediatePaybackReceiver, address(underlyingToken), flashLoanAmount, "");

        assertEq(credit(address(immediatePaybackReceiver)), 0);
        assertEq(virtualDebt(vault, address(immediatePaybackReceiver)), 0);
        assertEq(credit(address(flashlender)), 0); // called paid zero fees
        assertEq(virtualDebt(vault, address(flashlender)), 0);
    }

    function test_mint_payback_low_fee() public {
        uint256 flashLoanAmount = 10 ether;
        uint256 expectedFee = flashlenderOne.flashFee(address(underlyingToken), flashLoanAmount);

        // assert fee is 1%
        assertEq(expectedFee, 10 ether * 1e16 / 1 ether);

        address treasury = liquidityPool.treasury();
        uint256 currentShares = liquidityPool.balanceOf(treasury);
        flashlenderOne.flashLoan(immediatePaybackReceiverOne, address(underlyingToken), flashLoanAmount, "");
        uint256 newShares = liquidityPool.balanceOf(treasury);

        assertEq(credit(address(immediatePaybackReceiverOne)), 0);
        assertEq(virtualDebt(vault, address(immediatePaybackReceiverOne)), 0);
        assertEq(newShares - currentShares, expectedFee); // expect that the treasury received the fees
        assertEq(virtualDebt(vault, address(flashlenderOne)), 0);
    }

    function test_mint_payback_high_fee() public {
        uint256 flashLoanAmount = 10 ether;
        uint256 expectedFee = flashlenderFive.flashFee(address(underlyingToken), flashLoanAmount);

        // assert fee is 5%
        assertEq(expectedFee, 10 ether * 5e16 / 1 ether);

        address treasury = liquidityPool.treasury();
        uint256 currentShares = liquidityPool.balanceOf(treasury);
        flashlenderFive.flashLoan(immediatePaybackReceiverFive, address(underlyingToken), flashLoanAmount, "");
        uint256 newShares = liquidityPool.balanceOf(treasury);

        assertEq(credit(address(immediatePaybackReceiverFive)), 0);
        assertEq(virtualDebt(vault, address(immediatePaybackReceiverFive)), 0);
        assertEq(newShares - currentShares, expectedFee); // expect that the treasury received the fees
        assertEq(virtualDebt(vault, address(flashlenderFive)), 0);
    }

    // // test mint() for amount_ == 0
    // function test_mint_zero_amount() public {
    //     flashlender.creditFlashLoan(immediatePaybackReceiver, 0, "");
    //     flashlender.flashLoan(immediatePaybackReceiver, address(stablecoin), 0, "");
    // }

    // // test mint() for amount_ > max borrowable amount
    // function test_mint_amount_over_max1() public {
    //     cdm.setParameter(address(flashlender), "debtCeiling", 10 ether);
    //     uint256 amount = flashlender.maxFlashLoan(address(stablecoin)) + 1 ether;
    //     vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
    //     flashlender.creditFlashLoan(immediatePaybackReceiver, amount, "");
    // }

    // function test_mint_amount_over_max2() public {
    //     cdm.setParameter(address(flashlender), "debtCeiling", 10 ether);
    //     uint256 amount = flashlender.maxFlashLoan(address(stablecoin)) + 1 ether;
    //     vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
    //     flashlender.flashLoan(immediatePaybackReceiver, address(stablecoin), amount, "");
    // }

    // // test max == 0 means flash minting is halted
    // function test_mint_max_zero1() public {
    //     cdm.setParameter(address(flashlender), "debtCeiling", 0);
    //     vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
    //     flashlender.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    // }

    // function test_mint_max_zero2() public {
    //     cdm.setParameter(address(flashlender), "debtCeiling", 0);
    //     vm.expectRevert(CDM.CDM__modifyBalance_debtCeilingExceeded.selector);
    //     flashlender.flashLoan(immediatePaybackReceiver, address(stablecoin), 10 ether, "");
    // }

    // // test reentrancy disallowed
    // function test_mint_reentrancy1() public {
    //     vm.expectRevert("ReentrancyGuard: reentrant call");
    //     flashlender.creditFlashLoan(reentrancyReceiver, 100 ether, "");
    // }

    // function test_mint_reentrancy2() public {
    //     vm.expectRevert("ReentrancyGuard: reentrant call");
    //     flashlender.flashLoan(reentrancyReceiver, address(stablecoin), 100 ether, "");
    // }

    // // test trading flash minted stablecoin for token and minting more stablecoin
    // function test_dex_trade() public {
    //     // Set the owner temporarily to allow the receiver to mint
    //     flashlender.flashLoan(dexTradeReceiver, address(stablecoin), 100 ether, "");
    // }

    // function test_max_flash_loan() public {
    //     assertEq(flashlender.maxFlashLoan(address(stablecoin)), uint256(type(int256).max));
    //     assertEq(flashlender.maxFlashLoan(address(minter)), 0); // Any other address should be 0 as per the spec
    // }

    // function test_flash_fee() public {
    //     assertEq(flashlender.flashFee(address(stablecoin), 100 ether), 0);
    //     assertEq(flashlenderOne.flashFee(address(stablecoin), 100 ether), 1 ether);
    //     assertEq(flashlenderFive.flashFee(address(stablecoin), 100 ether), 5 ether);
    // }

    // function test_flash_fee_unsupported_token() public {
    //     vm.expectRevert(Flashlender.Flash__flashFee_unsupportedToken.selector);
    //     flashlender.flashFee(address(minter), 100 ether); // Any other address should fail
    // }

    // function test_bad_token() public {
    //     vm.expectRevert(Flashlender.Flash__flashLoan_unsupportedToken.selector);
    //     flashlender.flashLoan(immediatePaybackReceiver, address(minter), 100 ether, "");
    // }

    // function test_bad_return_hash1() public {
    //     vm.expectRevert(Flashlender.Flash__creditFlashLoan_callbackFailed.selector);
    //     flashlender.creditFlashLoan(badReturn, 100 ether, "");
    // }

    // function test_bad_return_hash2() public {
    //     vm.expectRevert(Flashlender.Flash__flashLoan_callbackFailed.selector);
    //     flashlender.flashLoan(badReturn, address(stablecoin), 100 ether, "");
    // }

    // function test_no_callbacks1() public {
    //     vm.expectRevert();
    //     flashlender.creditFlashLoan(ICreditFlashBorrower(address(noCallbacks)), 100 ether, "");
    // }

    // function test_no_callbacks2() public {
    //     vm.expectRevert();
    //     flashlender.flashLoan(IERC3156FlashBorrower(address(noCallbacks)), address(stablecoin), 100 ether, "");
    // }
}