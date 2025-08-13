// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IVaultRegistry} from "../../interfaces/IVaultRegistry.sol";
import {IMultiFeeDistribution} from "../../reward/interfaces/IMultiFeeDistribution.sol";
import {IPriceProvider} from "../../reward/interfaces/IPriceProvider.sol";
import {IChefIncentivesController} from "../../reward/interfaces/IChefIncentivesController.sol";
import {BalancerPoolHelper} from "../../reward/BalancerPoolHelper.sol";
import {IWeightedPoolFactory, IWeightedPool} from "../../reward/interfaces/balancer/IWeightedPoolFactory.sol";
import {wdiv} from "../../utils/Math.sol";
import {IVault as IBalancerVault, JoinKind, JoinPoolRequest} from "../../vendor/IBalancerVault.sol";
import {IntegrationTestBase, IComposableStablePool} from "../integration/IntegrationTestBase.sol";
import {CDPVault} from "../../CDPVault.sol";
import {ICDPVault} from "../../interfaces/ICDPVault.sol";
import {ChefIncentivesController} from "../../reward/ChefIncentivesController.sol";
import {EligibilityDataProvider} from "../../reward/EligibilityDataProvider.sol";
import {MultiFeeDistribution} from "../../reward/MultiFeeDistribution.sol";
import {LockedBalance, EarnedBalance} from "../../reward/interfaces/LockedBalance.sol";
import {VaultRegistry} from "../../VaultRegistry.sol";
import {MockChainlinkOracle} from "../MockChainlinkOracle.sol";
import {MockPriceProvider} from "../MockPriceProvider.sol";

interface IWETH {
    function deposit() external payable;
}

contract RadiantDeployHelper {
    event LoopTokenDeployed(address indexed tokenAddress);
    event PriceProviderDeployed(address indexed priceProviderAddress);
    event PoolHelperDeployed(address indexed poolHelperAddress);
    event WeightedPoolInitialized(address indexed poolAddress);

    using SafeERC20 for ERC20;

    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    ERC20 internal constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IWeightedPoolFactory internal constant WEIGHTED_POOL_FACTORY = 
        IWeightedPoolFactory(0x897888115Ada5773E02aA29F775430BFB5F34c51);

    address public loopToken;
    IWETH public weth = IWETH(address(WETH));
    BalancerPoolHelper public poolHelper;

    uint256 public loopIndex = 0;
    uint256 public wethIndex = 1;

    function deployLoopToken(uint256 mintAmount) external returns (ERC20Mock loopToken_) {
        loopToken_ = new ERC20Mock();
        loopToken_.mint(address(this), mintAmount);
        loopToken = address(loopToken_);
        emit LoopTokenDeployed(loopToken);
    }

    function wrapETH(uint256 amount) external {
        weth.deposit{value: amount}();
    }

    function deployPriceProvider() external returns (MockPriceProvider priceProvider_) {
        priceProvider_ = new MockPriceProvider();
        emit PriceProviderDeployed(address(priceProvider_));
    }

        function deployPoolHelper() external returns (BalancerPoolHelper poolHelper_) {
        require(loopToken != address(0), "Loop token must be deployed first");
        
        poolHelper_ = BalancerPoolHelper(
            address(
                new ERC1967Proxy(
                    address(new BalancerPoolHelper(loopToken)),
                    abi.encodeWithSelector(
                        BalancerPoolHelper.initialize.selector,
                        address(WETH),     // inTokenAddr (WETH)
                        loopToken,         // outTokenAddr (Loop token)
                        address(WETH),     // wethAddr
                        BALANCER_VAULT,    // vault (Balancer Vault)
                        WEIGHTED_POOL_FACTORY  // poolFactory
                    )
                )
            )
        );
        poolHelper = poolHelper_;
        emit PoolHelperDeployed(address(poolHelper_));
    }

    // Assumes we have WETH and loopToken, will initialize pool using BalancerPoolHelper
    function initializePoolWithHelper() external returns (address pool_) {
        require(address(poolHelper) != address(0), "Pool helper must be deployed first");
        
        uint256 wethBalance = WETH.balanceOf(address(this));
        uint256 loopBalance = ERC20(loopToken).balanceOf(address(this));
        
        require(wethBalance > 0 && loopBalance > 0, "Must have both WETH and Loop tokens");

        // Transfer tokens to the pool helper for initialization
        WETH.safeTransfer(address(poolHelper), wethBalance);
        ERC20(loopToken).safeTransfer(address(poolHelper), loopBalance);

        // Initialize the pool using the pool helper (we are the owner)
        poolHelper.initializePool("80LOOP-20WETH", "80LOOP-20WETH");
        
        // Get the pool address
        pool_ = poolHelper.lpTokenAddr();
        
        // Set indices for compatibility with existing tests
        // In an 80/20 pool, Loop is first (higher weight)
        loopIndex = 0;
        wethIndex = 1;
        
        emit WeightedPoolInitialized(pool_);
    }

    function grantPoolHelperZapperRole(address zapperAddress) external {
        require(address(poolHelper) != address(0), "Pool helper must be deployed first");
        poolHelper.grantZapperRole(zapperAddress);
    }

    receive() external payable {}
}

contract TokenomicsTest is IntegrationTestBase {
    using SafeERC20 for ERC20;

    CDPVault public vault;
    ChefIncentivesController public incentivesController;
    EligibilityDataProvider public eligibilityDataProvider;
    MultiFeeDistribution public multiFeeDistribution;
    MockPriceProvider public priceProvider;

    ERC20Mock public loopToken;
    MockChainlinkOracle public mockCollateralOracle;
    BalancerPoolHelper public poolHelper;

    RadiantDeployHelper public radiantDeployHelper;

    // mocked contracts
    address public lockZap;
    address public dao;

    // MultiFeeDistribution params
    uint256 public rewardsDuration = 30 days;
    uint256 public rewardsLookback = 5 days;
    uint256 public lockDuration = 30 days;
    uint256 public burnRatio = 50000; // 50%
    uint256 public vestDuration = 30 days;

    //ChefIncentivesController params
    uint256 public rewardsPerSecond = 0.01 ether;
    uint256 public endingTimeCadence = 2 days;

    IComposableStablePool internal govWeightedPool;
    bytes32 internal govWeightedPoolId;
    ERC20 internal lpToken;

    function setUp() public virtual override {
        super.setUp();

        radiantDeployHelper = new RadiantDeployHelper();
        loopToken = radiantDeployHelper.deployLoopToken(5_000_000 ether);

        priceProvider = radiantDeployHelper.deployPriceProvider();

        setOraclePrice(2400 ether);

        mockTreasury = vm.addr(uint256(keccak256("mockTreasury")));
        lockZap = vm.addr(uint256(keccak256("lockZap")));
        dao = vm.addr(uint256(keccak256("dao")));

        // Deploy and initialize the pool helper
        poolHelper = radiantDeployHelper.deployPoolHelper();
        
        // Provide liquidity for pool initialization
        deal(address(WETH), address(radiantDeployHelper), 5_000_000 ether);
        
        // Initialize the pool using the BalancerPoolHelper
        address poolAddress = radiantDeployHelper.initializePoolWithHelper();
        govWeightedPool = IComposableStablePool(poolAddress);
        govWeightedPoolId = govWeightedPool.getPoolId();
        lpToken = ERC20(poolAddress);

        // setup the vault registry
        vault = createCDPVault(token, 100_000 ether, 10 ether, 1 ether, 1 ether, 0);
        createGaugeAndSetGauge(address(vault));

        // Setup mock oracle for collateral token (returns 1 USD in 18 decimals)
        mockCollateralOracle = new MockChainlinkOracle(18, 1e18);
        vaultRegistry.setTokenOracle(address(token), mockCollateralOracle);

        multiFeeDistribution = MultiFeeDistribution(
            address(
                new ERC1967Proxy(
                    address(new MultiFeeDistribution()),
                    abi.encodeWithSelector(
                        MultiFeeDistribution.initialize.selector,
                        address(loopToken),
                        lockZap,
                        dao,
                        address(priceProvider),
                        rewardsDuration,
                        rewardsLookback,
                        lockDuration,
                        burnRatio,
                        vestDuration
                    )
                )
            )
        );

        eligibilityDataProvider = EligibilityDataProvider(
            address(
                new ERC1967Proxy(
                    address(new EligibilityDataProvider()),
                    abi.encodeWithSelector(
                        EligibilityDataProvider.initialize.selector,
                        IVaultRegistry(address(vaultRegistry)),
                        IMultiFeeDistribution(address(multiFeeDistribution)),
                        IPriceProvider(address(priceProvider))
                    )
                )
            )
        );

        incentivesController = ChefIncentivesController(
            address(
                new ERC1967Proxy(
                    address(new ChefIncentivesController()),
                    abi.encodeWithSelector(
                        ChefIncentivesController.initialize.selector,
                        address(this),
                        address(eligibilityDataProvider),
                        IMultiFeeDistribution(address(multiFeeDistribution)),
                        rewardsPerSecond,
                        address(loopToken),
                        endingTimeCadence
                    )
                )
            )
        );

        uint256 _allocPoint = 100;
        incentivesController.addPool(address(vault), _allocPoint);
        eligibilityDataProvider.setChefIncentivesController(IChefIncentivesController(address(incentivesController)));
        vault.setParameter("rewardController", address(incentivesController));
        _setupMultiFeeDistribution();

        incentivesController.start();

        vm.label(address(vault), "vault");
        vm.label(address(incentivesController), "incentivesController");
        vm.label(address(multiFeeDistribution), "multiFeeDistribution");
        vm.label(address(eligibilityDataProvider), "eligibilityDataProvider");
        vm.label(address(vaultRegistry), "vaultRegistry");
        vm.label(address(priceProvider), "priceProvider");
        vm.label(address(loopToken), "loopToken");
        vm.label(lockZap, "lockZap");
        vm.label(dao, "dao");
        vm.label(mockTreasury, "mockTreasury");
        vm.label(address(lpToken), "stakingToken");
    }

    function _setupMultiFeeDistribution() internal {
        uint256[] memory lockDurations = new uint256[](4);
        uint256[] memory rewardMultipliers = new uint256[](4);
        lockDurations[0] = 2592000;
        lockDurations[1] = 7776000;
        lockDurations[2] = 15552000;
        lockDurations[3] = 31104000;

        rewardMultipliers[0] = 1;
        rewardMultipliers[1] = 4;
        rewardMultipliers[2] = 10;
        rewardMultipliers[3] = 25;

        multiFeeDistribution.setLockTypeInfo(lockDurations, rewardMultipliers);
        multiFeeDistribution.setAddresses(IChefIncentivesController(address(incentivesController)), mockTreasury);
        multiFeeDistribution.setLPToken(address(govWeightedPool));

        address[] memory minters = new address[](1);
        minters[0] = address(incentivesController);
        multiFeeDistribution.setMinters(minters);
    }

    function _registerRewards(uint256 rewardAmount) internal {
        loopToken.mint(address(this), rewardAmount);
        loopToken.transfer(address(incentivesController), rewardAmount);
        incentivesController.registerRewardDeposit(rewardAmount);
    }

    function _borrow(address user, uint256 collateral, uint256 normalDebt) internal {
        token.mint(user, collateral);
        vm.startPrank(user);
        token.approve(address(vault), collateral);
        vault.modifyCollateralAndDebt(user, user, user, int256(collateral), int256(normalDebt));
        vm.stopPrank();
    }

    function _depositInPool(address user, uint256 amount) internal {
        loopToken.mint(user, amount);

        uint256 wethLiquidityAmt = amount;
        deal(address(WETH), user, wethLiquidityAmt);
        address[] memory assets = new address[](2);

        assets[radiantDeployHelper.wethIndex()] = address(WETH);
        assets[radiantDeployHelper.loopIndex()] = address(loopToken);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[radiantDeployHelper.wethIndex()] = wethLiquidityAmt;
        maxAmountsIn[radiantDeployHelper.loopIndex()] = amount;

        vm.startPrank(user);
        loopToken.approve(address(balancerVault), amount);
        WETH.approve(address(balancerVault), wethLiquidityAmt);

        balancerVault.joinPool(
            govWeightedPoolId,
            address(user),
            address(user),
            JoinPoolRequest({
                assets: assets,
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn),
                fromInternalBalance: false
            })
        );
        vm.stopPrank();
    }

    function test_deploy() public {
        assertNotEq(address(loopToken), address(0));
        assertNotEq(address(vaultRegistry), address(0));
        assertNotEq(address(multiFeeDistribution), address(0));
        assertNotEq(address(eligibilityDataProvider), address(0));
        assertNotEq(address(incentivesController), address(0));
    }

    function test_registerRewards() public {
        uint256 rewardAmount = 1_000_000 ether;
        _registerRewards(rewardAmount);
        assertEq(rewardAmount, incentivesController.depositedRewards());
        assertEq(0, incentivesController.accountedRewards());
        assertEq(rewardAmount, loopToken.balanceOf(address(incentivesController)));
    }

    function test_borrow() public {
        uint256 rewardAmount = 1_000_000 ether;
        _registerRewards(rewardAmount);
        address user = vm.addr(uint256(keccak256("user")));
        uint256 collateral = 100 ether;
        uint256 debt = 50 ether;

        _borrow(user, collateral, debt);

        bool isEligible = eligibilityDataProvider.isEligibleForRewards(user);
        assertEq(isEligible, false);
    }

    function test_borrow_withRewards() public {
        uint256 rewardAmount = 1_000_000 ether;
        _registerRewards(rewardAmount);

        address user = vm.addr(uint256(keccak256("user")));
        uint256 collateral = 100 ether;
        uint256 debt = 50 ether;
        _borrow(user, collateral, debt);

        uint256 requiredUSD = eligibilityDataProvider.requiredUsdValue(user);
        emit log_named_uint("requiredUSD", requiredUSD);

        uint256 depositNeededForReward = 2.51 ether / 2;
        _depositInPool(user, depositNeededForReward);

        uint256 balance = ERC20(address(govWeightedPool)).balanceOf(user);
        emit log_named_uint("lp balance", balance);
        emit log_named_uint("lp balance USD", balance * 2400);

        vm.startPrank(user);
        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), balance);
        multiFeeDistribution.stake(balance, user, 0);
        vm.stopPrank();

        uint256 lockedUSD = eligibilityDataProvider.lockedUsdValue(user);
        emit log_named_uint("lockedUSD", lockedUSD);

        eligibilityDataProvider.setPriceToleranceRatio(8000);

        uint256 priceToleranceRatio = eligibilityDataProvider.priceToleranceRatio();
        uint256 requiredValue = (requiredUSD * priceToleranceRatio) / 10000;
        emit log_named_uint("requiredValue", requiredValue);

        bool isEligible = eligibilityDataProvider.isEligibleForRewards(user);
        assertEq(isEligible, true);

        uint256 pendingRewards = incentivesController.allPendingRewards(user);
        assertEq(pendingRewards, 0);
        emit log_named_uint("1 pendingRewards", pendingRewards);

        vm.warp(block.timestamp + 30 days);

        pendingRewards = incentivesController.allPendingRewards(user);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory vaultPendingRewards = incentivesController.pendingRewards(user, vaults);
        assertEq(vaultPendingRewards.length, 1);
        assertEq(pendingRewards, vaultPendingRewards[0]);
    }

    function test_claimRewards() public {
        address user = vm.addr(uint256(keccak256("user")));
        _registerRewards(1_000_000 ether);
        _borrow(user, 100 ether, 50 ether);

        uint256 depositNeededForReward = 2.51 ether / 2;
        _depositInPool(user, depositNeededForReward);

        vm.startPrank(user);

        LockedBalance[] memory lockInfo = multiFeeDistribution.lockInfo(user);
        assertEq(lockInfo.length, 0);

        uint256 balance = ERC20(address(govWeightedPool)).balanceOf(user);
        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), balance);
        multiFeeDistribution.stake(balance, user, 0);

        vm.warp(block.timestamp + 30 days);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256 pendingRewards = incentivesController.allPendingRewards(user);
        //uint256[] memory pendingRewards = incentivesController.pendingRewards(user, vaults);

        vm.stopPrank();

        lockInfo = multiFeeDistribution.lockInfo(user);
        assertEq(lockInfo.length, 1);

        // claim must be called by the user themselves
        vm.prank(user);
        incentivesController.claim(user, vaults);

        (uint256 totalVesting, uint256 unlocked, EarnedBalance[] memory earnedBalances) = multiFeeDistribution
            .earnedBalances(user);

        assertEq(totalVesting, pendingRewards);
        assertEq(unlocked, 0);

        vm.warp(earnedBalances[0].unlockTime + 1);

        vm.startPrank(user);
        uint256 balanceBefore = loopToken.balanceOf(user);
        multiFeeDistribution.withdraw(totalVesting);
        uint256 balanceAfter = loopToken.balanceOf(user);
        vm.stopPrank();
        assertEq(balanceAfter - balanceBefore, totalVesting);
    }

    function test_multipleLocks() public {
        address user = vm.addr(uint256(keccak256("user")));
        _registerRewards(1_000_000 ether);
        _borrow(user, 100 ether, 50 ether);

        uint256 depositNeededForReward = 10 ether;
        _depositInPool(user, depositNeededForReward);

        vm.startPrank(user);

        LockedBalance[] memory lockInfo = multiFeeDistribution.lockInfo(user);
        assertEq(lockInfo.length, 0);

        uint256 totalBalance = ERC20(address(govWeightedPool)).balanceOf(user);

        uint256 lockAmount = totalBalance / 4;
        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), lockAmount);
        multiFeeDistribution.stake(lockAmount, user, 0);

        lockInfo = multiFeeDistribution.lockInfo(user);
        assertEq(lockInfo.length, 1);

        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), lockAmount);
        multiFeeDistribution.stake(lockAmount, user, 0);

        // we should still have 1 lock because they should be merged
        lockInfo = multiFeeDistribution.lockInfo(user);
        assertEq(lockInfo.length, 1);

        // create a new lock on the same block but with a different type
        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), lockAmount);
        multiFeeDistribution.stake(lockAmount, user, 1);

        // we should have 2 locks now because of different end times caused by the different lock types
        lockInfo = multiFeeDistribution.lockInfo(user);
        assertEq(lockInfo.length, 2);

        vm.warp(block.timestamp + multiFeeDistribution.AGGREGATION_EPOCH());

        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), lockAmount);
        multiFeeDistribution.stake(lockAmount, user, 1);

        lockInfo = multiFeeDistribution.lockInfo(user);
        assertEq(lockInfo.length, 3);
    }

    function test_rewardAttackScenario() public {
        _registerRewards(1_000_000 ether);
        address rugger = vm.addr(uint256(keccak256("rugger")));

        address[] memory minters = new address[](1);
        minters[0] = rugger;
        multiFeeDistribution.setMinters(minters);

        address randomUser;
        for (uint i = 0; i < 20; ++i) {
            randomUser = vm.addr(uint256(keccak256(abi.encode("user", i))));
            uint256 randomUserStake = 20 ether;
            _borrow(randomUser, 1_000 ether, 500 ether);
            _depositInPool(randomUser, randomUserStake);

            vm.startPrank(randomUser);
            uint256 balance = ERC20(address(govWeightedPool)).balanceOf(randomUser);
            ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), balance);
            multiFeeDistribution.stake(balance, randomUser, 3);
            vm.stopPrank();
            assertEq(eligibilityDataProvider.isEligibleForRewards(randomUser), true);
        }

        LockedBalance[] memory lockInfo = multiFeeDistribution.lockInfo(randomUser);
        uint256 unlockTime = lockInfo[0].unlockTime;
        uint256 lockedAmount = lockInfo[0].amount;

        vm.warp(block.timestamp + unlockTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);

        for (uint i = 0; i < 20; ++i) {
            randomUser = vm.addr(uint256(keccak256(abi.encode("user", i))));
            vm.prank(randomUser);
            incentivesController.claim(randomUser, vaults);
        }

        uint256 totalBalance = loopToken.balanceOf(address(multiFeeDistribution));

        vm.startPrank(rugger);
        multiFeeDistribution.vestTokens(rugger, totalBalance, false);
        (uint256 rugAmount, , ) = multiFeeDistribution.withdrawableBalance(rugger);
        multiFeeDistribution.withdraw(rugAmount);
        assertEq(rugAmount, totalBalance);
        vm.stopPrank();

        for (uint i = 0; i < 20; ++i) {
            randomUser = vm.addr(uint256(keccak256(abi.encode("user", i))));
            (uint256 amount, , ) = multiFeeDistribution.withdrawableBalance(randomUser);
            vm.startPrank(randomUser);
            vm.expectRevert("ERC20: transfer amount exceeds balance");
            multiFeeDistribution.withdraw(amount);

            uint256 balanceBefore = lpToken.balanceOf(randomUser);
            lockInfo = multiFeeDistribution.lockInfo(randomUser);
            lockedAmount = lockInfo[0].amount;
            multiFeeDistribution.withdrawExpiredLocksForWithOptions(randomUser, 0, false);
            uint256 balanceAfter = lpToken.balanceOf(randomUser);
            assertEq(balanceAfter - balanceBefore, lockedAmount);
            vm.stopPrank();
        }
    }

    function test_poolHelperFunctionality() public {
        // Test that the pool helper was properly initialized
        assertEq(poolHelper.lpTokenAddr(), address(lpToken), "LP token address should match");
        assertEq(poolHelper.inTokenAddr(), address(WETH), "Input token should be WETH");
        assertEq(poolHelper.outTokenAddr(), address(loopToken), "Output token should be Loop token");

        // Grant this test contract the zapper role to allow calling zap functions
        // The radiantDeployHelper is the admin, so we need to call from there
        radiantDeployHelper.grantPoolHelperZapperRole(address(this));

        // Test pool deposit functionality (zapWETH)
        uint256 wethAmount = 2 ether;
        deal(address(WETH), address(this), wethAmount);
        WETH.approve(address(poolHelper), wethAmount);

        // Get LP token for balance tracking
        ERC20 poolLpToken = ERC20(poolHelper.lpTokenAddr());
        uint256 lpBalanceBefore = poolLpToken.balanceOf(address(this));

        // Test zapWETH - deposit WETH into the pool to get LP tokens
        uint256 lpReceived = poolHelper.zapWETH(wethAmount);
        
        uint256 lpBalanceAfter = poolLpToken.balanceOf(address(this));
        assertTrue(lpReceived > 0, "Should receive LP tokens from WETH deposit");
        assertEq(lpBalanceAfter - lpBalanceBefore, lpReceived, "LP balance increase should match returned amount");

        // Test zapTokens - deposit both WETH and Loop tokens
        uint256 additionalWeth = 1 ether;
        uint256 loopAmount = 100 ether; // Provide some loop tokens
        
        deal(address(WETH), address(this), additionalWeth);
        deal(address(loopToken), address(this), loopAmount);
        
        WETH.approve(address(poolHelper), additionalWeth);
        loopToken.approve(address(poolHelper), loopAmount);

        uint256 lpBalanceBeforeZap = poolLpToken.balanceOf(address(this));
        uint256 lpFromBothTokens = poolHelper.zapTokens(additionalWeth, loopAmount);
        uint256 lpBalanceAfterZap = poolLpToken.balanceOf(address(this));
        
        assertTrue(lpFromBothTokens > 0, "Should receive LP tokens from both token deposit");
        assertEq(lpBalanceAfterZap - lpBalanceBeforeZap, lpFromBothTokens, "LP balance should increase correctly");
    }
    
    function test_chefIncentivesController_tracksCollateralNotDebt() public {
        uint256 rewardAmount = 1_000_000 ether;
        _registerRewards(rewardAmount);
        
        address user = vm.addr(uint256(keccak256("userCollateralTest")));
        
        // Create position with DIFFERENT debt and collateral amounts
        uint256 collateralAmount = 200 ether;    // Higher collateral
        uint256 debtAmount = 80 ether;           // Lower debt (40% LTV)
        
        _borrow(user, collateralAmount, debtAmount);
        
        // Verify vault has the expected different amounts
        (uint256 vaultCollateral, uint256 vaultDebt, , , , ) = vault.positions(user);
        assertEq(vaultCollateral, collateralAmount, "Vault should have expected collateral");
        assertEq(vaultDebt, debtAmount, "Vault should have expected debt");
        assertNotEq(vaultCollateral, vaultDebt, "Collateral and debt should be different");
        
        // Make user eligible for rewards (this triggers the reward tracking logic)
        uint256 depositNeededForReward = 2.51 ether / 2;
        _depositInPool(user, depositNeededForReward);
        
        vm.startPrank(user);
        uint256 lpBalance = ERC20(address(govWeightedPool)).balanceOf(user);
        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), lpBalance);
        multiFeeDistribution.stake(lpBalance, user, 0);
        vm.stopPrank();
        
        // Verify user is eligible
        bool isEligible = eligibilityDataProvider.isEligibleForRewards(user);
        assertTrue(isEligible, "User should be eligible for rewards");
        
        // Get the tracked amount in ChefIncentivesController
        (uint256 trackedAmount, , ) = incentivesController.userInfo(address(vault), user);
        
        assertEq(trackedAmount, vaultCollateral, "ChefIncentivesController should track collateral");
        assertNotEq(trackedAmount, vaultDebt, "ChefIncentivesController should NOT track debt");
        
        // Verify pool total also reflects collateral tracking
        (uint256 poolTotalSupply, , , ) = incentivesController.vaultInfo(address(vault));
        assertEq(poolTotalSupply, vaultCollateral, "Pool total should reflect collateral");
    }
    
    function test_chefIncentivesController_multipleUsersCollateralTracking() public {
        // Test with multiple users having different debt/collateral ratios
        uint256 rewardAmount = 1_000_000 ether;
        _registerRewards(rewardAmount);
        
        address user1 = vm.addr(uint256(keccak256("user1CollateralTest")));
        address user2 = vm.addr(uint256(keccak256("user2CollateralTest")));
        address user3 = vm.addr(uint256(keccak256("user3CollateralTest")));
        
        // Create positions with VERY different debt/collateral ratios
        uint256 user1Collateral = 300 ether;
        uint256 user1Debt = 60 ether;    // 20% LTV
        
        uint256 user2Collateral = 150 ether;  
        uint256 user2Debt = 120 ether;   // 80% LTV
        
        uint256 user3Collateral = 500 ether;
        uint256 user3Debt = 400 ether;   // 80% LTV
        
        _borrow(user1, user1Collateral, user1Debt);
        _borrow(user2, user2Collateral, user2Debt);
        _borrow(user3, user3Collateral, user3Debt);
        
        // Make all users eligible for rewards
        uint256 depositNeededForReward = 2.51 ether / 2;
        _depositInPool(user1, depositNeededForReward);
        _depositInPool(user2, depositNeededForReward);
        _depositInPool(user3, depositNeededForReward);
        
        // Stake for all users
        for (uint i = 0; i < 3; i++) {
            address currentUser = i == 0 ? user1 : (i == 1 ? user2 : user3);
            vm.startPrank(currentUser);
            uint256 lpBalance = ERC20(address(govWeightedPool)).balanceOf(currentUser);
            ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), lpBalance);
            multiFeeDistribution.stake(lpBalance, currentUser, 0);
            vm.stopPrank();
        }
        
        // Verify all users are eligible
        assertTrue(eligibilityDataProvider.isEligibleForRewards(user1), "User1 should be eligible");
        assertTrue(eligibilityDataProvider.isEligibleForRewards(user2), "User2 should be eligible");
        assertTrue(eligibilityDataProvider.isEligibleForRewards(user3), "User3 should be eligible");
        
        // Get tracked amounts for all users
        (uint256 tracked1, , ) = incentivesController.userInfo(address(vault), user1);
        (uint256 tracked2, , ) = incentivesController.userInfo(address(vault), user2);
        (uint256 tracked3, , ) = incentivesController.userInfo(address(vault), user3);
        
        assertEq(tracked1, user1Collateral, "User1: Should track collateral");
        assertEq(tracked2, user2Collateral, "User2: Should track collateral");
        assertEq(tracked3, user3Collateral, "User3: Should track collateral");
        
        assertNotEq(tracked1, user1Debt, "User1: Should NOT track debt");
        assertNotEq(tracked2, user2Debt, "User2: Should NOT track debt");
        assertNotEq(tracked3, user3Debt, "User3: Should NOT track debt");
        
        // Verify pool total is sum of collaterals, not debts
        (uint256 poolTotalSupply, , , ) = incentivesController.vaultInfo(address(vault));
        uint256 expectedTotal = user1Collateral + user2Collateral + user3Collateral;
        uint256 wrongTotal = user1Debt + user2Debt + user3Debt;
        
        assertEq(poolTotalSupply, expectedTotal, "Pool total should be sum of collaterals");
        assertNotEq(poolTotalSupply, wrongTotal, "Pool total should NOT be sum of debts");
        
        emit log_named_uint("Expected total (collaterals)", expectedTotal);
        emit log_named_uint("Wrong total (debts)", wrongTotal);
        emit log_named_uint("Actual tracked total", poolTotalSupply);
    }
    
    function test_chefIncentivesController_collateralTrackingAfterPositionChanges() public {
        // Test that tracking remains correct after position modifications
        uint256 rewardAmount = 1_000_000 ether;
        _registerRewards(rewardAmount);
        
        address user = vm.addr(uint256(keccak256("userPositionChanges")));
        
        // Initial position
        uint256 initialCollateral = 100 ether;
        uint256 initialDebt = 30 ether;
        _borrow(user, initialCollateral, initialDebt);
        
        // Make user eligible
        uint256 depositNeededForReward = 2.51 ether / 2;
        _depositInPool(user, depositNeededForReward);
        
        vm.startPrank(user);
        uint256 lpBalance = ERC20(address(govWeightedPool)).balanceOf(user);
        ERC20(address(govWeightedPool)).approve(address(multiFeeDistribution), lpBalance);
        multiFeeDistribution.stake(lpBalance, user, 0);
        vm.stopPrank();
        
        // Verify initial tracking
        (uint256 initialTracked, , ) = incentivesController.userInfo(address(vault), user);
        (uint256 vaultCollateral1, uint256 vaultDebt1, , , , ) = vault.positions(user);
        assertEq(initialTracked, vaultCollateral1, "Initial: Should track collateral");
        
        // Modify position - add more collateral and debt
        uint256 additionalCollateral = 50 ether;
        uint256 additionalDebt = 40 ether;
        
        token.mint(user, additionalCollateral);
        vm.startPrank(user);
        token.approve(address(vault), additionalCollateral);
        vault.modifyCollateralAndDebt(
            user, user, user, 
            int256(additionalCollateral), 
            int256(additionalDebt)
        );
        vm.stopPrank();
        
        // Verify updated tracking after position change
        (uint256 updatedTracked, , ) = incentivesController.userInfo(address(vault), user);
        (uint256 vaultCollateral2, uint256 vaultDebt2, , , , ) = vault.positions(user);
        
        // Final position should have different collateral vs debt
        uint256 expectedFinalCollateral = initialCollateral + additionalCollateral;
        uint256 expectedFinalDebt = initialDebt + additionalDebt;
        
        assertEq(vaultCollateral2, expectedFinalCollateral, "Vault should have updated collateral");
        assertEq(vaultDebt2, expectedFinalDebt, "Vault should have updated debt");
        assertNotEq(vaultCollateral2, vaultDebt2, "Final collateral should differ from debt");
        
        // Tracking should still follow collateral, not debt
        assertEq(updatedTracked, vaultCollateral2, "After changes: Should track collateral");
        assertNotEq(updatedTracked, vaultDebt2, "After changes: Should NOT track debt");
    }
}
