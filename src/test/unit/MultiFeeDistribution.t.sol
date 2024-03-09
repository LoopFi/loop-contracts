// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {TestBase} from "../TestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {WAD} from "../../utils/Math.sol";
import {IVaultRegistry} from "../../interfaces/IVaultRegistry.sol";
import {MultiFeeDistribution} from "../../reward/MultiFeeDistribution.sol";
import {IMultiFeeDistribution} from "../../reward/interfaces/IMultiFeeDistribution.sol";
import {IPriceProvider} from "../../reward/interfaces/IPriceProvider.sol";
import {IChefIncentivesController} from "../../reward/interfaces/IChefIncentivesController.sol";
import {LockedBalance, Balances, EarnedBalance} from "../../reward/interfaces/LockedBalance.sol";
import {Reward} from "../../reward/interfaces/LockedBalance.sol";

contract MultiFeeDistributionTest is TestBase {
    using SafeERC20 for IERC20;

    MultiFeeDistribution internal multiFeeDistribution;
    ERC20Mock public loopToken;
    ERC20Mock public stakeToken;

    address internal incentiveController;
    address internal mockPriceProvider;
    address internal mockLockZap;
    address internal mockDao;

    uint256 public rewardsDuration = 30 days;
    uint256 public rewardsLookback = 5 days;
    uint256 public lockDuration = 30 days;
    uint256 public burnRatio = 50000; // 50%
    uint256 public vestDuration = 30 days;

    uint256[] public lockDurations;

    function setUp() public override virtual{
        super.setUp();

        mockPriceProvider = vm.addr(uint256(keccak256("mockPriceProvider")));
        mockLockZap = vm.addr(uint256(keccak256("lockZap")));
        mockDao = vm.addr(uint256(keccak256("dao")));
        incentiveController = vm.addr(uint256(keccak256("incentiveController")));

        loopToken = new ERC20Mock();
        stakeToken = new ERC20Mock();

        multiFeeDistribution = MultiFeeDistribution(address(new ERC1967Proxy(
            address(new MultiFeeDistribution()),
            abi.encodeWithSelector(
                MultiFeeDistribution.initialize.selector,
                address(loopToken),
                mockLockZap,
                mockDao,
                mockPriceProvider,
                rewardsDuration,
                rewardsLookback,
                lockDuration,
                burnRatio,
                vestDuration
            )
        )));

        vm.mockCall(
            mockPriceProvider, 
            abi.encodeWithSelector(IPriceProvider.update.selector), 
            abi.encode(true)
        );
        
        vm.label(address(loopToken), "loopToken");
        vm.label(address(stakeToken), "stakeToken");
        vm.label(address(multiFeeDistribution), "multiFeeDistribution");
        vm.label(address(incentiveController), "incentivesController");
    }

    function _addLockDurations() internal returns (uint256 len) {
        len = 4;
        lockDurations = new uint256[](len);
        uint256[] memory rewardMultipliers = new uint256[](len);
        lockDurations[0] = 2592000;
        lockDurations[1] = 7776000;
        lockDurations[2] = 15552000;
        lockDurations[3] = 31104000;

        rewardMultipliers[0] = 1; 
        rewardMultipliers[1] = 4;
        rewardMultipliers[2] = 10;
        rewardMultipliers[3] = 25;

        multiFeeDistribution.setLockTypeInfo(lockDurations, rewardMultipliers);
    }

    function _stake(address user, uint256 amount, uint256 typeIndex) internal {
        uint256[] memory locks = multiFeeDistribution.getLockDurations();
        uint256 len = locks.length;
        if(len == 0) {
            len = _addLockDurations();
        }
        stakeToken.mint(address(this), amount);
        multiFeeDistribution.setLPToken(address(stakeToken));

        address treasury = vm.addr(uint256(keccak256("treasury")));
        multiFeeDistribution.setAddresses(IChefIncentivesController(incentiveController), treasury);

        vm.mockCall(
            incentiveController,
            abi.encodeWithSelector(IChefIncentivesController.afterLockUpdate.selector, user),
            abi.encode(true)
        );

        stakeToken.approve(address(multiFeeDistribution), amount);            
        multiFeeDistribution.stake(amount, user, typeIndex);
    }

    function _excludeContracts(address address_) internal view {
        vm.assume(
            address_ != mockPriceProvider && 
            address_ != mockLockZap &&
            address_ != mockDao &&
            address_ != address(loopToken) &&
            address_ != address(stakeToken) &&
            address_ != address(0)
        );
    }

    function test_deploy() public {
        assertNotEq(address(multiFeeDistribution), address(0));
        assertEq(address(loopToken), address(multiFeeDistribution.rdntToken()));
        assertEq(mockDao, multiFeeDistribution.daoTreasury());
        assertEq(rewardsDuration, multiFeeDistribution.rewardsDuration());
        assertEq(rewardsLookback, multiFeeDistribution.rewardsLookback());
        assertEq(lockDuration, multiFeeDistribution.defaultLockDuration());
        assertEq(burnRatio, multiFeeDistribution.burn());
        assertEq(vestDuration, multiFeeDistribution.vestDuration());
    }

    function test_setMinters(address minter1, address minter2) public {
        _excludeContracts(minter1);
        _excludeContracts(minter2);
        vm.assume(minter1 != address(0) && minter2 != address(0));
        address[] memory minters = new address[](2);
        minters[0] = minter1;
        minters[1] = minter2;

        multiFeeDistribution.setMinters(minters);
        assertTrue(multiFeeDistribution.minters(minter1));
        assertTrue(multiFeeDistribution.minters(minter2));

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(0x1));
        multiFeeDistribution.setMinters(minters);

        minters[0] = address(0);
        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.setMinters(minters);
    }

    function test_setBountyManager(address bountyManager) public {
        _excludeContracts(bountyManager);
        multiFeeDistribution.setBountyManager(bountyManager);
        assertEq(bountyManager, multiFeeDistribution.bountyManager());

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(0x1));
        multiFeeDistribution.setBountyManager(bountyManager);

        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.setBountyManager(address(0));
    }

    function test_addRewardConverter(address converter) public {
        _excludeContracts(converter);
        multiFeeDistribution.addRewardConverter(converter);
        assertEq(multiFeeDistribution.rewardConverter(), converter);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(0x1));
        multiFeeDistribution.addRewardConverter(converter);

        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.addRewardConverter(address(0));
    }

    function test_setLockTypeInfo() public {
        uint256 len = _addLockDurations();

        (uint256[] memory locks) = multiFeeDistribution.getLockDurations();
        assertEq(locks.length, len);
        assertEq(locks[0], 2592000);
        assertEq(locks[1], 7776000);
        assertEq(locks[2], 15552000);
        assertEq(locks[3], 31104000);

        (uint256[] memory rewardMultipliers) = multiFeeDistribution.getLockMultipliers();
        assertEq(rewardMultipliers.length, 4);
        assertEq(rewardMultipliers[0], 1);
        assertEq(rewardMultipliers[1], 4);
        assertEq(rewardMultipliers[2], 10);
        assertEq(rewardMultipliers[3], 25);
    }

    function test_setAddresses(address controller, address treasury) public {
        _excludeContracts(controller);
        _excludeContracts(treasury);
        multiFeeDistribution.setAddresses(IChefIncentivesController(controller), treasury);
        assertEq(controller, address(multiFeeDistribution.incentivesController()));
        assertEq(treasury, address(multiFeeDistribution.starfleetTreasury()));

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(0x1));
        multiFeeDistribution.setAddresses(IChefIncentivesController(controller), treasury);

        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.setAddresses(IChefIncentivesController(address(0)), treasury);

        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.setAddresses(IChefIncentivesController(controller), address(0));
    }

    function test_setLPToken(address lpToken) public {
        _excludeContracts(lpToken);
        multiFeeDistribution.setLPToken(lpToken);
        assertEq(lpToken, multiFeeDistribution.stakingToken());

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(0x1));
        multiFeeDistribution.setLPToken(lpToken);

        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.setLPToken(address(0));

        vm.expectRevert(MultiFeeDistribution.AlreadySet.selector);
        multiFeeDistribution.setLPToken(lpToken);
    }

    function test_addReward(address rewardToken) public {
        _excludeContracts(rewardToken);

        // we are not a minter
        vm.expectRevert(MultiFeeDistribution.InsufficientPermission.selector);
        multiFeeDistribution.addReward(rewardToken);

        // add minter
        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);

        assertFalse(multiFeeDistribution.isRewardToken(rewardToken));
        // add the reward token
        multiFeeDistribution.addReward(rewardToken);
        assertTrue(multiFeeDistribution.isRewardToken(rewardToken));

        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.addReward(address(0));
    }

    function test_addReward_updatesRewardData(address rewardToken) public {
        _excludeContracts(rewardToken);
        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.addReward(rewardToken);

        (uint256 periodFinish,,uint256 lastUpdateTime,,)= multiFeeDistribution.rewardData(rewardToken);
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(periodFinish, block.timestamp);
    }

    function test_removeReward(address rewardToken) public {
        _excludeContracts(rewardToken);

        vm.expectRevert(MultiFeeDistribution.InsufficientPermission.selector);
        multiFeeDistribution.removeReward(rewardToken);

        // add minter
        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);

        multiFeeDistribution.addReward(rewardToken);
        assertTrue(multiFeeDistribution.isRewardToken(rewardToken));

        multiFeeDistribution.removeReward(rewardToken);
        assertFalse(multiFeeDistribution.isRewardToken(rewardToken));

        // token is already removed
        vm.expectRevert(MultiFeeDistribution.InvalidAddress.selector);
        multiFeeDistribution.removeReward(rewardToken);
    }

    function test_removeReward_removesRewardData(address rewardToken) public {
        _excludeContracts(rewardToken);
        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.addReward(rewardToken);

        multiFeeDistribution.removeReward(rewardToken);
        (
            uint256 periodFinish,
            uint256 rewardPerSecond, 
            uint256 lastUpdateTime, 
            uint256 rewardPerTokenStored, 
            uint256 balance
        )= multiFeeDistribution.rewardData(rewardToken);

        assertEq(periodFinish, 0);
        assertEq(rewardPerSecond, 0);
        assertEq(lastUpdateTime, 0);
        assertEq(rewardPerTokenStored, 0);
        assertEq(balance, 0);
    }

    function test_setDefaultRelockTypeIndex(address sender, uint256 index) public {
        _excludeContracts(sender);
        uint256 len = _addLockDurations();
        index = index % len;

        vm.prank(sender);
        multiFeeDistribution.setDefaultRelockTypeIndex(index);
        assertEq(index, multiFeeDistribution.defaultLockIndex(sender));

        vm.expectRevert(MultiFeeDistribution.InvalidType.selector);
        vm.prank(sender);
        multiFeeDistribution.setDefaultRelockTypeIndex(len);
    }

    function test_setAutocompound(address sender, bool value, uint256 slippage) public {
        _excludeContracts(sender);
        // constant could be renamed
        uint256 minSlippage = multiFeeDistribution.MAX_SLIPPAGE();

        // exclude the PERCENT_DIVISOR() value from the maxSlippage
        uint256 maxSlippage = multiFeeDistribution.PERCENT_DIVISOR()-1;

        slippage = bound(slippage, minSlippage, maxSlippage);

        vm.prank(sender);
        multiFeeDistribution.setAutocompound(value, slippage);

        assertEq(value, multiFeeDistribution.autocompoundEnabled(sender));
        assertEq(slippage, multiFeeDistribution.userSlippage(sender));

        vm.expectRevert(MultiFeeDistribution.InvalidAmount.selector);
        vm.prank(sender);
        multiFeeDistribution.setAutocompound(value, minSlippage-1);

        vm.expectRevert(MultiFeeDistribution.InvalidAmount.selector);
        vm.prank(sender);
        multiFeeDistribution.setAutocompound(value, maxSlippage+1);
    }

    function test_setUserSlippage(address user, uint256 slippage) public {
        _excludeContracts(user);
        uint256 minSlippage = multiFeeDistribution.MAX_SLIPPAGE();
        uint256 maxSlippage = multiFeeDistribution.PERCENT_DIVISOR()-1;
        slippage = bound(slippage, minSlippage, maxSlippage);

        vm.prank(user);
        multiFeeDistribution.setUserSlippage(slippage);
        assertEq(slippage, multiFeeDistribution.userSlippage(user));

        vm.expectRevert(MultiFeeDistribution.InvalidAmount.selector);
        vm.prank(user);
        multiFeeDistribution.setUserSlippage(minSlippage-1);

        vm.expectRevert(MultiFeeDistribution.InvalidAmount.selector);
        vm.prank(user);
        multiFeeDistribution.setUserSlippage(maxSlippage+1);
    } 

    function test_toggleAutocompound(address sender) public {
        _excludeContracts(sender);
        vm.prank(sender);
        multiFeeDistribution.toggleAutocompound();
        assertTrue(multiFeeDistribution.autocompoundEnabled(sender));

        vm.prank(sender);
        multiFeeDistribution.toggleAutocompound();
        assertFalse(multiFeeDistribution.autocompoundEnabled(sender));
    }

    function test_setRelock(address sender, bool status) public {
        vm.prank(sender);
        multiFeeDistribution.setRelock(status);
        assertEq(status, !multiFeeDistribution.autoRelockDisabled(sender));
    }

    function test_setLookback(uint256 lookback) public {
        uint256 duration = multiFeeDistribution.rewardsDuration();
        lookback = bound(lookback, 1, duration);

        multiFeeDistribution.setLookback(lookback);
        assertEq(lookback, multiFeeDistribution.rewardsLookback());

        vm.expectRevert(MultiFeeDistribution.InvalidLookback.selector);
        multiFeeDistribution.setLookback(duration+1);

        vm.expectRevert(MultiFeeDistribution.AmountZero.selector);
        multiFeeDistribution.setLookback(0);

        vm.prank(address(0x1));
        vm.expectRevert("Ownable: caller is not the owner");
        multiFeeDistribution.setLookback(lookback);
    }

    function test_setOperationExpenses(address receiver, uint256 expenseRatio) public {
        _excludeContracts(receiver);
        
        uint256 maxRatio = multiFeeDistribution.RATIO_DIVISOR();
        expenseRatio = bound(expenseRatio, 0, maxRatio);

        multiFeeDistribution.setOperationExpenses(receiver, expenseRatio);
        assertEq(expenseRatio, multiFeeDistribution.operationExpenseRatio());
        assertEq(receiver, multiFeeDistribution.operationExpenseReceiver());

        vm.expectRevert(MultiFeeDistribution.InvalidRatio.selector);
        multiFeeDistribution.setOperationExpenses(receiver, maxRatio+1);

        vm.expectRevert(MultiFeeDistribution.AddressZero.selector);
        multiFeeDistribution.setOperationExpenses(address(0), expenseRatio);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(0x1));
        multiFeeDistribution.setOperationExpenses(receiver, expenseRatio);
    }

    function test_stake(address onBehalfOf, uint256 typeIndex) public {
        _excludeContracts(onBehalfOf);

        uint256 amount = 10 ether;
        uint256 len = _addLockDurations();
        typeIndex = typeIndex % len;
        _stake(onBehalfOf, amount, typeIndex);
    }

    function test_vestTokens(address user, uint256 amount, bool withPenalty) public {
        _excludeContracts(user);

        amount = amount % 1000 ether;
        loopToken.mint(address(this), amount);
        loopToken.approve(address(multiFeeDistribution), amount);

        vm.expectRevert(MultiFeeDistribution.InsufficientPermission.selector);
        multiFeeDistribution.vestTokens(user, amount, withPenalty);

        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.vestTokens(user, amount, withPenalty);
    }

    function test_withdraw_withoutPenalty(address user) public {
        _excludeContracts(user);

        uint256 amount = 1000 ether;
        loopToken.mint(address(multiFeeDistribution), amount);

        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.vestTokens(user, amount, false);

        (uint256 availableAmount, uint256 penaltyAmount, uint256 burnAmount) = multiFeeDistribution.withdrawableBalance(user);
        assertEq(availableAmount, amount);
        assertEq(penaltyAmount, 0);
        assertEq(burnAmount, 0);

        assertEq(loopToken.balanceOf(user), 0);
        vm.prank(user);
        vm.mockCall(
            mockPriceProvider, 
            abi.encodeWithSelector(IPriceProvider.update.selector), 
            abi.encode(true)
        );
        multiFeeDistribution.withdraw(amount);
        assertEq(loopToken.balanceOf(user), availableAmount);
    }

    function test_withdraw_withPenalty(address user) public {
        _excludeContracts(user);

        uint256 amount = 1000 ether;
        loopToken.mint(address(multiFeeDistribution), amount);

        address treasury = vm.addr(uint256(keccak256("treasury")));
        multiFeeDistribution.setAddresses(IChefIncentivesController(incentiveController), treasury);

        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.vestTokens(user, amount, true);
        vm.warp(block.timestamp + 2 days);

        (uint256 availableAmount, uint256 penaltyAmount, uint256 burnAmount) = multiFeeDistribution.withdrawableBalance(user);
        assertLe(availableAmount, amount);
        assertGt(penaltyAmount, 0);
        assertGt(burnAmount, 0);

        assertEq(loopToken.balanceOf(user), 0);
        
        vm.mockCall(
            mockPriceProvider, 
            abi.encodeWithSelector(IPriceProvider.update.selector), 
            abi.encode(true)
        );
        vm.prank(user);
        multiFeeDistribution.withdraw(availableAmount);
        assertEq(loopToken.balanceOf(user), availableAmount);
        assertEq(loopToken.balanceOf(treasury), burnAmount);
    }

    function test_individualEarlyExit_withoutClaim(address user) public {
        _excludeContracts(user);

        uint256 amount = 1000 ether;
        loopToken.mint(address(multiFeeDistribution), amount);

        address treasury = vm.addr(uint256(keccak256("treasury")));
        multiFeeDistribution.setAddresses(IChefIncentivesController(incentiveController), treasury);

        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.vestTokens(user, amount, true);

        (uint256 totalVesting, uint256 unlocked, EarnedBalance[] memory earnedBalances) = multiFeeDistribution.earnedBalances(user);
        assertEq(totalVesting, amount);
        assertEq(unlocked, 0);
        assertEq(earnedBalances.length, 1);

        uint256 unlockTime = earnedBalances[0].unlockTime;
        vm.prank(user);
        multiFeeDistribution.individualEarlyExit(false, unlockTime);

        uint256 userExpected = amount / 10;
        uint256 penalty = amount - userExpected;
        assertEq(loopToken.balanceOf(user), userExpected); 
        assertEq(loopToken.balanceOf(treasury), penalty / 2);
        assertEq(loopToken.balanceOf(mockDao), penalty / 2);
    }

    function test_individualEarlyExit_withClaim(address user) public {
        _excludeContracts(user);

        uint256 amount = 1000 ether;
        loopToken.mint(address(multiFeeDistribution), amount);

        address treasury = vm.addr(uint256(keccak256("treasury")));
        multiFeeDistribution.setAddresses(IChefIncentivesController(incentiveController), treasury);

        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.vestTokens(user, amount, true);

        (uint256 totalVesting, uint256 unlocked, EarnedBalance[] memory earnedBalances) = multiFeeDistribution.earnedBalances(user);
        assertEq(totalVesting, amount);
        assertEq(unlocked, 0);
        assertEq(earnedBalances.length, 1);

        vm.mockCall(
            incentiveController,
            abi.encodeWithSelector(IChefIncentivesController.setEligibilityExempt.selector, user, true),
            abi.encode(true)
        );

        uint256 unlockTime = earnedBalances[0].unlockTime;
        vm.prank(user);
        multiFeeDistribution.individualEarlyExit(true, unlockTime);

        uint256 userExpected = amount / 10;
        uint256 penalty = amount - userExpected;
        assertEq(loopToken.balanceOf(user), userExpected); 
        assertEq(loopToken.balanceOf(treasury), penalty / 2);
        assertEq(loopToken.balanceOf(mockDao), penalty / 2);
    }

    function test_withdrawExpiredLocksForWithOptions(address user) public {
        _excludeContracts(user);

        _stake(user, 1000 ether, 0);
        LockedBalance[] memory locks = multiFeeDistribution.lockInfo(user);
        uint256 unlockTime = locks[0].unlockTime;
        vm.warp(unlockTime + 1);

        vm.prank(user);
        multiFeeDistribution.withdrawExpiredLocksForWithOptions(user, 1, false);
        locks = multiFeeDistribution.lockInfo(user);
        assertEq(locks.length, 0);
        assertEq(stakeToken.balanceOf(user), 1000 ether);
    }

    function test_exit_claimUnlockedBalances(address user) public {
        _excludeContracts(user);

        uint256 amount = 1000 ether;
        loopToken.mint(address(multiFeeDistribution), amount);

        address treasury = vm.addr(uint256(keccak256("treasury")));
        multiFeeDistribution.setAddresses(IChefIncentivesController(incentiveController), treasury);

        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.vestTokens(user, amount, true);

        vm.mockCall(
            incentiveController,
            abi.encodeWithSelector(IChefIncentivesController.setEligibilityExempt.selector, user, true),
            abi.encode(true)
        );

        (uint256 totalVesting, uint256 unlocked, EarnedBalance[] memory earnedBalances) = multiFeeDistribution.earnedBalances(user);
        uint256 unlockTime = earnedBalances[0].unlockTime;
        vm.warp(unlockTime + 1);
        vm.prank(user);
        multiFeeDistribution.exit(true);

        assertEq(loopToken.balanceOf(user), amount); 
        assertEq(loopToken.balanceOf(treasury), 0);
        assertEq(loopToken.balanceOf(mockDao), 0);
    }

    function test_exit_withPenalty(address user) public {
        _excludeContracts(user);

        uint256 amount = 1000 ether;
        loopToken.mint(address(multiFeeDistribution), amount);

        address treasury = vm.addr(uint256(keccak256("treasury")));
        multiFeeDistribution.setAddresses(IChefIncentivesController(incentiveController), treasury);

        address[] memory minters = new address[](1);
        minters[0] = address(this);
        multiFeeDistribution.setMinters(minters);
        multiFeeDistribution.vestTokens(user, amount, true);

        vm.mockCall(
            incentiveController,
            abi.encodeWithSelector(IChefIncentivesController.setEligibilityExempt.selector, user, true),
            abi.encode(true)
        );

        (uint256 totalVesting, uint256 unlocked, EarnedBalance[] memory earnedBalances) = multiFeeDistribution.earnedBalances(user);
        uint256 unlockTime = earnedBalances[0].unlockTime;
        vm.prank(user);
        multiFeeDistribution.exit(true);

        uint256 userExpected = amount / 10;
        uint256 penalty = amount - userExpected;
        assertEq(loopToken.balanceOf(user), userExpected); 
        assertEq(loopToken.balanceOf(treasury), penalty / 2);
        assertEq(loopToken.balanceOf(mockDao), penalty / 2);
    }
}
