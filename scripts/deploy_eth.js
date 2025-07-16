const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const axios = require('axios');
const { BigNumber } = require('ethers');
const { BalancerSDK, Network, PoolType } = require('@balancer-labs/sdk');
const { ethers } = require('hardhat');
const {
  getSignerAddress,
  getDeploymentFilePath,
  storeContractDeployment,
  deployContract,
  isContractDeployed,
  getDeployedContract,
  attachContract,
  loadDeployedContracts,
  loadDeployedVaults,
  verifyOnTenderly,
  convertBigNumberToString,
  replaceParams,
  storeEnvMetadata,
  storeVaultMetadata,
  getVaultMetadata,
  getPoolAddress,
  deployPoolCore,
  deployStakingAndLockingLP,
  deployActions,
  deployPositionActions,
  deployVaultOracle,
  registerVaults,
  deployPools,
  impersonateAccount,
  stopImpersonatingAccount,
  deployGauge
} = require('./utils/deployUtils');
const { 
  getNetworkName, 
  loadConfig 
} = require('./utils/configUtils');

// Hardcode the config type for this specific deployment script
const CONFIG_TYPE = 'eth';

// Load the network-specific and/or token-specific config
const CONFIG_NETWORK = loadConfig(CONFIG_TYPE);

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);
const toWad = ethers.utils.parseEther;
const fromWad = ethers.utils.formatEther;
const toBytes32 = ethers.utils.formatBytes32String;

// Function to initialize the deployment with account impersonation
async function impersonateDeployer() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                       INITIALIZING DEPLOYMENT
//////////////////////////////////////////////////////////////*/
  `);

  // Address to impersonate
  const accountToImpersonate = "0x9B2205E4E62e333141117Fc895DC77B558E2a2BC";
  
  // Get original signer for reference
  const originalSigner = await getSignerAddress();
  console.log(`Original deployer: ${originalSigner}`);
  
  // Impersonate the account and set it as default signer
  const impersonatedSigner = await impersonateAccount(accountToImpersonate);
  console.log(`Now deploying as impersonated account: ${accountToImpersonate}`);
  
  // Check if the impersonation was successful
  const currentSigner = await getSignerAddress();
  console.log(`Current deployer after impersonation: ${currentSigner}`);
  
  return impersonatedSigner;
}

// Function to cleanup after deployment
async function finalizeDeployment() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        FINALIZING DEPLOYMENT
//////////////////////////////////////////////////////////////*/
  `);
  
  // Address that was impersonated
  const accountToImpersonate = "0x9B2205E4E62e333141117Fc895DC77B558E2a2BC";
  
  // Stop impersonating
  await stopImpersonatingAccount(accountToImpersonate);
  console.log(`Stopped impersonating account: ${accountToImpersonate}`);
}

async function deployCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING CORE
//////////////////////////////////////////////////////////////*/
  `);

  // Pass CONFIG_NETWORK to deployPoolCore
  const deployedCore = await deployPoolCore(CONFIG_NETWORK, 'eth');
  console.log('Core deployment completed');
  return deployedCore;
}

async function deployVaults() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING VAULTS
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();
  const prbProxyRegistry = await attachContract('PRBProxyRegistry', CONFIG_NETWORK.Core.ProxyRegistry);
  for (const [key, config] of Object.entries(CONFIG_NETWORK.Vaults)) {
    const vaultName = `CDPVault_${key}`;
    console.log('deploying vault ', vaultName);

    // Deploy oracle using the common function with CONFIG_NETWORK
    const oracleAddress = await deployVaultOracle(key, config, {
      'tETH': async (key, config) => {
        // ETH-specific tETH oracle deployment logic here if needed
        const oracleConfig = config.oracle.deploymentArguments;
        const deployedOracle = await deployContract(
          config.oracle.type,
          config.oracle.type+'_'+key,
          false,
          ...Object.values(oracleConfig)
        );
        return deployedOracle.address;
      },
      'SpectraInwstETHOracle': async (key, config) => {
        return await deploySpectraInwstETHOracle(key, config);
      }
    }, CONFIG_NETWORK);
    
    if (!oracleAddress) continue;

    var token;
    var tokenAddress = config.token;
    let tokenScale = config.tokenScale;
    let tokenSymbol = config.tokenSymbol;

    // initialize the token
    if (tokenAddress == undefined || tokenAddress == null) {
      console.log('Deploying token for', key);
      token = await deployContract(
        'ERC20PresetMinterPauser',
        'MockCollateralToken',
        false,
        "MockCollateralToken",
        "MCT"
      );
      tokenAddress = token.address;
      tokenScale = new ethers.BigNumber.from(10).pow(await token.decimals());
      tokenSymbol = "MCT";
    }

    const poolAddress = await getPoolAddress(config.poolAddress);
    if (!poolAddress) {
      console.log(`ERROR: Could not find pool address for ${config.poolAddress}`);
      continue;
    }

    // Verify this is actually a Pool contract
    try {
      const pool = await attachContract('PoolV3', poolAddress);
      const underlyingToken = await pool.underlyingToken();
      console.log(`Verified pool at ${poolAddress} with underlying token: ${underlyingToken}`);
    } catch (error) {
      console.error(`ERROR: Address ${poolAddress} is not a valid PoolV3 contract:`, error.message);
      continue;
    }

    console.log(`Proceeding with vault deployment using pool: ${poolAddress}`);

    const cdpVault = await deployContract(
      config.type,
      vaultName,
      true,
      [
        poolAddress,
        oracleAddress,
        tokenAddress,
        tokenScale
      ],
      [
        ...Object.values(config.deploymentArguments.configs).map((v) => v === "deployer" ? signer : v)
      ]
    );

    console.log('CDPVault deployed for', vaultName, 'at', cdpVault.address);

    console.log('Set debtCeiling to', fromWad(config.deploymentArguments.debtCeiling), 'for', vaultName);
    const pool = await attachContract('PoolV3', poolAddress);
    await pool.setCreditManagerDebtLimit(cdpVault.address, config.deploymentArguments.debtCeiling);
    
    console.log('------------------------------------');

    console.log('Initialized', vaultName, 'with a debt ceiling of', fromWad(config.deploymentArguments.debtCeiling), 'Credit');

    const rewardManager = await deployContract(
      config.RewardManager.artifactName,
      `RewardManager_${key}`,
      false,
      cdpVault.address,
      tokenAddress,
      prbProxyRegistry.address,
      ...Object.values(config.RewardManager.constructorArguments).map(v => v === "deployer" ? signer : v)
    );

    // Store reward manager with vault reference
    await storeContractDeployment(
      false,
      `RewardManager_${key}`,
      rewardManager.address,
      config.RewardManager.artifactName,
      [
        cdpVault.address,
        tokenAddress,
        prbProxyRegistry.address,
        ...Object.values(config.RewardManager.constructorArguments)
      ],
      {
        vaultName: vaultName,
        vaultAddress: cdpVault.address
      }
    );

    console.log('Deployed RewardManager for', vaultName, 'at', rewardManager.address);

    await cdpVault["setParameter(bytes32,address)"](toBytes32("rewardManager"), rewardManager.address);
    console.log('Set reward manager for', vaultName, 'to', rewardManager.address);

    await storeVaultMetadata(
      cdpVault.address,
      {
        contractName: vaultName,
        name: config.name,
        description: config.description,
        artifactName: 'CDPVault',
        pool: pool.address,
        oracle: oracleAddress,
        token: tokenAddress,
        tokenScale: tokenScale,
        quotas: config.quotas
      }
    );

    console.log('------------------------------------');
    console.log('');
  }
}

async function deployInterestRateModel() {

  //default values
  const U_1 = 7000; // U_1
  const U_2 = 9000; // U_2
  const R_base = 0; // R_base
  const R_slope1 = 612; // R_slope1
  const R_slope2 = 765; // R_slope2
  const R_slope3 = 765; // R_slope3
  const version = 5;

  //decrease factor for slopes
  const decreaseFactor = 0.7; // 30% decrease

  // Round up the decreased values using Math.ceil
  const R_slope1_decreased = Math.ceil(R_slope1 * decreaseFactor);
  const R_slope2_decreased = Math.ceil(R_slope2 * decreaseFactor);
  const R_slope3_decreased = Math.ceil(R_slope3 * decreaseFactor);

  console.log('Deploying LinearInterestRateModelV3');
  console.log('U_1:', U_1);
  console.log('U_2:', U_2);
  console.log('R_base:', R_base);
  console.log('R_slope1:', R_slope1_decreased, `(${R_slope1} * ${decreaseFactor} rounded up)`);
  console.log('R_slope2:', R_slope2_decreased, `(${R_slope2} * ${decreaseFactor} rounded up)`);
  console.log('R_slope3:', R_slope3_decreased, `(${R_slope3} * ${decreaseFactor} rounded up)`);
  console.log('version:', version);

  const LinearInterestRateModelV3 = await deployContract(
    'LinearInterestRateModelV3',
    `LinearInterestRateModelV3_${version}`,
    false,
    U_1,
    U_2,
    R_base,
    R_slope1_decreased,
    R_slope2_decreased,
    R_slope3_decreased,
    false
  );

  return LinearInterestRateModelV3;
}

async function redeployActions() {
  const poolType = 'eth';
  const config = CONFIG_NETWORK;

  const swapAction = await deployContract(
    'SwapAction',
    `SwapAction_${poolType}`,
    false,
    ...Object.values(config.Core.Actions.SwapAction.constructorArguments)
  );

  const poolAction = await deployContract(
    'PoolAction',
    `PoolAction_${poolType}`,
    false,
    ...Object.values(config.Core.Actions.PoolAction.constructorArguments)
  );

  const flashlender = await attachContract('Flashlender', CONFIG_NETWORK.Core.FlashlenderLPEth);
  const vaultRegistry = await attachContract('VaultRegistry', CONFIG_NETWORK.Core.VaultRegistry);

  await deployPositionActions(flashlender, swapAction, poolAction, vaultRegistry, poolType, config);
}

// Standalone function for deploying SpectraInwstETHOracle as a proxy
async function deploySpectraInwstETHOracle(key, config) {
  console.log('Deploying SpectraInwstETHOracle for', key);
  const oracleConfig = config.oracle.deploymentArguments;
  
  // Step 1: Deploy the WstEthOracle
  const wstETHOracle = await deployContract(
    'AggregatorV3WstEthOracle',
    'AggregatorV3WstEthOracle_'+key,
    false,
    oracleConfig.wstEth
  );
  console.log('Deployed WstEthOracle at', wstETHOracle.address);

  // Step 2: Deploy the CombinedOracle
  const combinedOracle = await deployContract(
    'CombinedAggregatorV3Oracle',
    'CombinedAggregatorV3Oracle_'+key,
    false,
    wstETHOracle.address,
    1, // 1 second heartbeat
    oracleConfig.stETHClOracle,
    oracleConfig.stalePeriod,
    true // true for mul, false for div
  );
  console.log('Deployed CombinedOracle at', combinedOracle.address);

  // Step 3: Deploy the implementation
  const spectraOracleImpl = await deployContract(
    'SpectraAggregatorV3Oracle',
    'SpectraAggregatorV3Oracle_Impl_'+key,
    false,
    oracleConfig.curvePool,
    oracleConfig.spectraIBT,
    combinedOracle.address,
    oracleConfig.stalePeriod
  );
  console.log('Deployed SpectraOracleImpl at', spectraOracleImpl.address);

  // Step 4: Deploy the proxy
  const signer = await getSignerAddress();
  
  // Get the contract factory for the proxy
  const ERC1967Proxy = await ethers.getContractFactory('ERC1967Proxy');
  
  // Create initialization data for the proxy
  const initData = spectraOracleImpl.interface.encodeFunctionData('initialize', [signer, signer]);
  
  // Deploy the proxy
  const proxy = await ERC1967Proxy.deploy(
    spectraOracleImpl.address,
    initData
  );
  await proxy.deployed();
  
  const spectraOracle = await ethers.getContractAt('SpectraAggregatorV3Oracle', proxy.address);
  console.log('Deployed SpectraOracle Proxy at', spectraOracle.address);
  
  // Step 5: Store all deployments
  await storeContractDeployment(
    false,
    'AggregatorV3WstEthOracle_'+key,
    wstETHOracle.address,
    'AggregatorV3WstEthOracle',
    [oracleConfig.wstEth]
  );
  
  await storeContractDeployment(
    false,
    'CombinedAggregatorV3Oracle_'+key,
    combinedOracle.address,
    'CombinedAggregatorV3Oracle',
    [wstETHOracle.address, 1, oracleConfig.stETHClOracle, oracleConfig.stalePeriod, true]
  );
  
  await storeContractDeployment(
    false,
    'SpectraAggregatorV3Oracle_Impl_'+key,
    spectraOracleImpl.address,
    'SpectraAggregatorV3Oracle',
    [oracleConfig.curvePool, oracleConfig.spectraIBT, combinedOracle.address, oracleConfig.stalePeriod]
  );
  
  await storeContractDeployment(
    false,
    'SpectraAggregatorV3Oracle_'+key,
    spectraOracle.address,
    'ERC1967Proxy',
    [spectraOracleImpl.address, initData]
  );
  
  return spectraOracle.address;
}

// Function to detect if we're on a local network (anvil/hardhat)
function isLocalNetwork() {
  const networkName = hre.network.name;
  const chainId = hre.network.config.chainId;
  
  // Common local network indicators
  const localNetworks = ['localhost', 'anvil', 'hardhat', 'local'];
  const localChainIds = [31337, 1337]; // Common local chain IDs
  
  return localNetworks.includes(networkName) || localChainIds.includes(chainId);
}

// Function to fund deployer with ETH and Loop tokens for local deployment
async function fundDeployerForLocalDeployment(loopToken) {
  if (!isLocalNetwork()) {
    console.log('Not on local network - skipping deployer funding');
    return;
  }

  console.log(`
/*//////////////////////////////////////////////////////////////
                    FUNDING DEPLOYER (LOCAL ONLY)
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await ethers.getImpersonatedSigner ? 
    await ethers.getImpersonatedSigner(await getSignerAddress()) : 
    (await ethers.getSigners())[0];
  
  const deployerAddress = await getSignerAddress();
  
  console.log('Funding deployer for local deployment:');
  console.log('- Network:', hre.network.name);
  console.log('- Chain ID:', hre.network.config.chainId);
  console.log('- Deployer:', deployerAddress);

  // Check current balances
  const currentEthBalance = await ethers.provider.getBalance(deployerAddress);
  const currentLoopBalance = await loopToken.balanceOf(deployerAddress);
  
  console.log('\nCurrent balances:');
  console.log('- ETH Balance:', fromWad(currentEthBalance));
  console.log('- Loop Balance:', fromWad(currentLoopBalance));

  // Required amounts for pool initialization
  const poolConfig = CONFIG_NETWORK.LiquidityPool;
  const requiredWeth = poolConfig.initialLiquidity.wethAmount;
  const requiredLoop = poolConfig.initialLiquidity.loopAmount;
  const extraEthForGas = toWad("10"); // Extra ETH for gas fees
  
  console.log('\nRequired amounts:');
  console.log('- WETH needed:', fromWad(requiredWeth));
  console.log('- Loop needed:', fromWad(requiredLoop));
  console.log('- Extra ETH for gas:', fromWad(extraEthForGas));

  // Fund with ETH if needed
  const totalEthNeeded = requiredWeth.add(extraEthForGas);
  if (currentEthBalance.lt(totalEthNeeded)) {
    const ethToAdd = totalEthNeeded.sub(currentEthBalance).add(toWad("1")); // Add 1 extra ETH buffer
    console.log('\n💰 Adding ETH to deployer...');
    console.log('- Amount to add:', fromWad(ethToAdd));
    
    // Use anvil_setBalance if available (for anvil)
    try {
      await hre.network.provider.send("anvil_setBalance", [
        deployerAddress,
        ethers.utils.hexStripZeros(currentEthBalance.add(ethToAdd).toHexString())
      ]);
      console.log('✅ ETH added via anvil_setBalance');
    } catch (error) {
      // Fallback: try hardhat_setBalance
      try {
        await hre.network.provider.send("hardhat_setBalance", [
          deployerAddress,
          ethers.utils.hexStripZeros(currentEthBalance.add(ethToAdd).toHexString())
        ]);
        console.log('✅ ETH added via hardhat_setBalance');
      } catch (fallbackError) {
        console.log('⚠️  Could not add ETH automatically. Please ensure sufficient ETH balance.');
        console.log('Manual funding may be required.');
      }
    }
  } else {
    console.log('✅ Deployer has sufficient ETH');
  }

  // Mint Loop tokens if needed
  if (currentLoopBalance.lt(requiredLoop)) {
    const loopToMint = requiredLoop.sub(currentLoopBalance).add(toWad("10000")); // Add 10k buffer
    console.log('\n🪙 Minting Loop tokens to deployer...');
    console.log('- Amount to mint:', fromWad(loopToMint));
    
    try {
      await loopToken.mint(deployerAddress, loopToMint);
      console.log('✅ Loop tokens minted successfully');
    } catch (error) {
      console.log('⚠️  Could not mint Loop tokens:', error.message);
      console.log('Please ensure the deployer has MINTER_ROLE');
    }
  } else {
    console.log('✅ Deployer has sufficient Loop tokens');
  }

  // Final balance check
  const finalEthBalance = await ethers.provider.getBalance(deployerAddress);
  const finalLoopBalance = await loopToken.balanceOf(deployerAddress);
  
  console.log('\nFinal balances after funding:');
  console.log('- ETH Balance:', fromWad(finalEthBalance));
  console.log('- Loop Balance:', fromWad(finalLoopBalance));
  
  const hasEnoughEth = finalEthBalance.gte(totalEthNeeded);
  const hasEnoughLoop = finalLoopBalance.gte(requiredLoop);
  
  if (hasEnoughEth && hasEnoughLoop) {
    console.log('✅ Deployer is properly funded for pool initialization');
  } else {
    console.log('⚠️  Deployer may not have sufficient funds:');
    if (!hasEnoughEth) console.log('   - Insufficient ETH');
    if (!hasEnoughLoop) console.log('   - Insufficient Loop tokens');
  }
}

// Function to deploy the Loop token
async function deployLoopToken() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING LOOP TOKEN
//////////////////////////////////////////////////////////////*/
  `);

  const tokenConfig = CONFIG_NETWORK.Tokenomics.LoopToken;
  const name = tokenConfig.name;
  const symbol = tokenConfig.symbol;
  const totalSupply = tokenConfig.totalSupply;

  console.log('Deploying Loop Token with:');
  console.log('- Name:', name);
  console.log('- Symbol:', symbol);
  console.log('- Total Supply:', fromWad(totalSupply));

  const loopToken = await deployContract(
    'ERC20PresetMinterPauser',
    'LoopToken',
    false,
    name,
    symbol
  );

  console.log('Loop Token deployed at:', loopToken.address);
  
  // Fund deployer for local deployment
  await fundDeployerForLocalDeployment(loopToken);
  
  return loopToken;
}

// Function to prepare tokens for pool initialization
async function prepareTokensForPoolInitialization(poolHelper, loopToken, wethAmount, loopAmount) {
  console.log('\n🔄 Preparing tokens for pool initialization...');
  
  const deployerAddress = await getSignerAddress();
  const WETH_ADDRESS = CONFIG_NETWORK.Core.WETH;
  
  // Get WETH contract (use IERC20 for view functions, IWETH for state-changing functions)
  const wethERC20 = await ethers.getContractAt('@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20', WETH_ADDRESS);
  const weth = await ethers.getContractAt('src/reward/interfaces/IWETH.sol:IWETH', WETH_ADDRESS);
  
  // Check current balances
  const currentEthBalance = await ethers.provider.getBalance(deployerAddress);
  const currentWethBalance = await wethERC20.balanceOf(deployerAddress);
  const currentLoopBalance = await loopToken.balanceOf(deployerAddress);
  
  console.log('Current deployer balances:');
  console.log('- ETH:', fromWad(currentEthBalance));
  console.log('- WETH:', fromWad(currentWethBalance));
  console.log('- Loop:', fromWad(currentLoopBalance));
  
  // Wrap ETH to WETH if needed
  if (currentWethBalance.lt(wethAmount)) {
    const wethNeeded = wethAmount.sub(currentWethBalance);
    console.log('\n💱 Wrapping ETH to WETH...');
    console.log('- WETH needed:', fromWad(wethNeeded));
    
    if (currentEthBalance.lt(wethNeeded)) {
      throw new Error(`Insufficient ETH balance. Need ${fromWad(wethNeeded)} WETH but only have ${fromWad(currentEthBalance)} ETH`);
    }
    
    const wrapTx = await weth.deposit({ value: wethNeeded });
    await wrapTx.wait();
    console.log('✅ ETH wrapped to WETH successfully');
    
    const newWethBalance = await wethERC20.balanceOf(deployerAddress);
    console.log('- New WETH balance:', fromWad(newWethBalance));
  } else {
    console.log('✅ Sufficient WETH balance available');
  }
  
  // Check Loop token balance
  if (currentLoopBalance.lt(loopAmount)) {
    const loopNeeded = loopAmount.sub(currentLoopBalance);
    console.log('\n⚠️  Insufficient Loop tokens!');
    console.log('- Loop needed:', fromWad(loopNeeded));
    console.log('- Current balance:', fromWad(currentLoopBalance));
    
    if (isLocalNetwork()) {
      console.log('🪙 Minting additional Loop tokens for local deployment...');
      await loopToken.mint(deployerAddress, loopNeeded);
      console.log('✅ Additional Loop tokens minted');
    } else {
      throw new Error(`Insufficient Loop token balance. Need ${fromWad(loopNeeded)} more Loop tokens`);
    }
  } else {
    console.log('✅ Sufficient Loop token balance available');
  }
  
  // Transfer tokens to the pool helper
  console.log('\n📤 Transferring tokens to pool helper...');
  console.log('- Pool helper address:', poolHelper.address);
  
  // Transfer WETH
  const wethTransferTx = await wethERC20.transfer(poolHelper.address, wethAmount);
  await wethTransferTx.wait();
  console.log('- WETH transferred:', fromWad(wethAmount));
  
  // Transfer Loop tokens
  const loopTransferTx = await loopToken.transfer(poolHelper.address, loopAmount);
  await loopTransferTx.wait();
  console.log('- Loop tokens transferred:', fromWad(loopAmount));
  
  // Verify the transfers
  const poolHelperWethBalance = await wethERC20.balanceOf(poolHelper.address);
  const poolHelperLoopBalance = await loopToken.balanceOf(poolHelper.address);
  
  console.log('\nPool helper balances after transfer:');
  console.log('- WETH:', fromWad(poolHelperWethBalance));
  console.log('- Loop:', fromWad(poolHelperLoopBalance));
  
  if (poolHelperWethBalance.gte(wethAmount) && poolHelperLoopBalance.gte(loopAmount)) {
    console.log('✅ Pool helper properly funded for initialization');
  } else {
    throw new Error('Pool helper funding verification failed');
  }
}

// Function to deploy the Balancer Pool Helper and initialize the liquidity pool
async function deployLiquidityPool() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                   DEPLOYING LIQUIDITY POOL
//////////////////////////////////////////////////////////////*/
  `);

  let loopToken = await getDeployedContract('LoopToken');
  if (!loopToken) {
    throw new Error('Loop Token must be deployed first');
  }
  
  // Ensure we have a contract instance, not just deployment info
  if (!loopToken.balanceOf) {
    console.log('Converting loopToken address to contract instance...');
    const loopTokenAddress = loopToken.address || loopToken;
    loopToken = await ethers.getContractAt('ERC20PresetMinterPauser', loopTokenAddress);
  }

  const signer = await getSignerAddress();
  const WETH = CONFIG_NETWORK.Core.WETH;
  const BALANCER_VAULT = CONFIG_NETWORK.Core.BalancerVault;
  const WEIGHTED_POOL_FACTORY = CONFIG_NETWORK.Core.WeightedPoolFactory;

  console.log('Deploying BalancerPoolHelper with:');
  console.log('- Loop Token:', loopToken.address);
  console.log('- WETH:', WETH);
  console.log('- Balancer Vault:', BALANCER_VAULT);
  console.log('- Pool Factory:', WEIGHTED_POOL_FACTORY);

  // Deploy the implementation
  const poolHelperImpl = await deployContract(
    'BalancerPoolHelper',
    'BalancerPoolHelper_Impl',
    false,
    loopToken.address
  );

  // Deploy the proxy
  const ERC1967Proxy = await ethers.getContractFactory('ERC1967Proxy');
  const initData = poolHelperImpl.interface.encodeFunctionData('initialize', [
    WETH,                    // inTokenAddr (WETH)
    loopToken.address,       // outTokenAddr (Loop token)
    WETH,                    // wethAddr
    BALANCER_VAULT,          // vault (Balancer Vault)
    WEIGHTED_POOL_FACTORY    // poolFactory
  ]);

  const proxy = await ERC1967Proxy.deploy(
    poolHelperImpl.address,
    initData
  );
  await proxy.deployed();

  const poolHelper = await ethers.getContractAt('BalancerPoolHelper', proxy.address);

  // Store both deployments
  await storeContractDeployment(
    false,
    'BalancerPoolHelper_Impl',
    poolHelperImpl.address,
    'BalancerPoolHelper',
    [loopToken.address]
  );

  await storeContractDeployment(
    false,
    'BalancerPoolHelper',
    poolHelper.address,
    'ERC1967Proxy',
    [poolHelperImpl.address, initData],
    {
      proxyType: 'ERC1967Proxy',
      implementation: poolHelperImpl.address,
      loopToken: loopToken.address
    }
  );

  // Initialize the pool if configured to do so
  const poolConfig = CONFIG_NETWORK.LiquidityPool;
  const initializePool = poolConfig?.initializeOnDeploy || false;
  
  console.log('Pool initialization configuration:');
  console.log('- Initialize on deploy:', initializePool);
  console.log('- Pool name:', poolConfig.poolName);
  console.log('- Pool symbol:', poolConfig.poolSymbol);
  
  if (initializePool) {
    console.log('\n🏊 Initializing Balancer Pool...');
    
    // Get liquidity amounts from config
    const wethAmount = poolConfig.initialLiquidity.wethAmount;
    const loopAmount = poolConfig.initialLiquidity.loopAmount;
    
    console.log('Initial liquidity configuration:');
    console.log('- WETH Amount:', fromWad(wethAmount));
    console.log('- Loop Amount:', fromWad(loopAmount));
    
    // Prepare tokens for pool initialization
    await prepareTokensForPoolInitialization(poolHelper, loopToken, wethAmount, loopAmount);
    
    // Initialize the pool
    const tx = await poolHelper.initializePool(poolConfig.poolName, poolConfig.poolSymbol);
    await tx.wait();
    console.log('✅ Pool initialization transaction completed');
    
    // Get pool information
    const lpTokenAddress = await poolHelper.lpTokenAddr();
    const poolId = await poolHelper.poolId();
    
    console.log('\n📊 Pool Deployment Results:');
    console.log('- LP Token Address:', lpTokenAddress);
    console.log('- Pool ID:', poolId);
    console.log('- Pool Name:', poolConfig.poolName);
    console.log('- Pool Symbol:', poolConfig.poolSymbol);
    
    // Store comprehensive LP token and pool info
    await storeContractDeployment(
      false,
      `LPToken_${poolConfig.poolSymbol}`,
      lpTokenAddress,
      'BalancerWeightedPool',
      [],
      {
        poolHelper: poolHelper.address,
        poolId: poolId,
        tokens: [WETH, loopToken.address],
        weights: ['200000000000000000', '800000000000000000'], // 20% WETH, 80% LOOP
        poolName: poolConfig.poolName,
        poolSymbol: poolConfig.poolSymbol,
        balancerVault: BALANCER_VAULT,
        deployer: await getSignerAddress(),
        deploymentTimestamp: Math.floor(Date.now() / 1000)
      }
    );
    
    console.log('✅ Pool information stored in deployment file');
    
    // Store pool information as a separate field
    await storePoolInformation(poolHelper, lpTokenAddress, poolId, poolConfig, wethAmount, loopAmount, false);
    
  } else {
    console.log('\n⚠️  Pool initialization is DISABLED in config');
    console.log('To initialize the pool later, set LiquidityPool.initializeOnDeploy = true in config');
    console.log('Or call the initializePoolManually() function after deployment');
  }

  console.log('BalancerPoolHelper deployed at:', poolHelper.address);
  return poolHelper;
}

// Function to manually initialize the pool after deployment
async function initializePoolManually() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                    MANUAL POOL INITIALIZATION
//////////////////////////////////////////////////////////////*/
  `);

  const poolHelper = await getDeployedContract('BalancerPoolHelper');
  if (!poolHelper) {
    throw new Error('BalancerPoolHelper must be deployed first');
  }

  const poolConfig = CONFIG_NETWORK.LiquidityPool;
  
  console.log('Initializing pool manually with configuration:');
  console.log('- Pool name:', poolConfig.poolName);
  console.log('- Pool symbol:', poolConfig.poolSymbol);
  console.log('- PoolHelper address:', poolHelper.address);

  // Check if pool is already initialized
  const currentLpToken = await poolHelper.lpTokenAddr();
  if (currentLpToken !== ethers.constants.AddressZero) {
    console.log('⚠️  Pool already initialized!');
    console.log('- Existing LP Token:', currentLpToken);
    const poolId = await poolHelper.poolId();
    console.log('- Existing Pool ID:', poolId);
    return { lpTokenAddress: currentLpToken, poolId };
  }

  console.log('\n🏊 Initializing Balancer Pool...');
  
  // Get required amounts
  const wethAmount = poolConfig.initialLiquidity.wethAmount;
  const loopAmount = poolConfig.initialLiquidity.loopAmount;
  const loopToken = await getDeployedContract('LoopToken');
  
  if (!loopToken) {
    throw new Error('Loop Token must be deployed before manual pool initialization');
  }
  
  // Prepare tokens for pool initialization
  await prepareTokensForPoolInitialization(poolHelper, loopToken, wethAmount, loopAmount);
  
  // Initialize the pool
  const tx = await poolHelper.initializePool(poolConfig.poolName, poolConfig.poolSymbol);
  await tx.wait();
  console.log('✅ Pool initialization transaction completed');
  
  // Get pool information
  const lpTokenAddress = await poolHelper.lpTokenAddr();
  const poolId = await poolHelper.poolId();
  
  console.log('\n📊 Pool Deployment Results:');
  console.log('- LP Token Address:', lpTokenAddress);
  console.log('- Pool ID:', poolId);
  console.log('- Pool Name:', poolConfig.poolName);
  console.log('- Pool Symbol:', poolConfig.poolSymbol);
  
  // Store comprehensive LP token and pool info
  await storeContractDeployment(
    false,
    `LPToken_${poolConfig.poolSymbol}`,
    lpTokenAddress,
    'BalancerWeightedPool',
    [],
    {
      poolHelper: poolHelper.address,
      poolId: poolId,
      tokens: [CONFIG_NETWORK.Core.WETH, loopToken.address],
      weights: ['200000000000000000', '800000000000000000'], // 20% WETH, 80% LOOP
      poolName: poolConfig.poolName,
      poolSymbol: poolConfig.poolSymbol,
      balancerVault: CONFIG_NETWORK.Core.BalancerVault,
      deployer: await getSignerAddress(),
      deploymentTimestamp: Math.floor(Date.now() / 1000)
    }
  );
  
  console.log('✅ Pool information stored in deployment file');
  
  // Store pool information as a separate field
  await storePoolInformation(poolHelper, lpTokenAddress, poolId, poolConfig, wethAmount, loopAmount, true);
  
  return { lpTokenAddress, poolId };
}

// Function to deploy reward contracts (MultiFeeDistribution, EligibilityDataProvider, ChefIncentivesController)
async function deployRewardContracts() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                   DEPLOYING REWARD CONTRACTS
//////////////////////////////////////////////////////////////*/
  `);

  let loopToken = await getDeployedContract('LoopToken');
  let poolHelper = await getDeployedContract('BalancerPoolHelper');
  let vaultRegistry = await getDeployedContract('VaultRegistry');
  
  console.log('Checking deployed contracts:');
  console.log('- LoopToken:', loopToken ? loopToken.address : 'NOT FOUND');
  console.log('- BalancerPoolHelper:', poolHelper ? poolHelper.address : 'NOT FOUND');
  console.log('- VaultRegistry:', vaultRegistry ? vaultRegistry.address : 'NOT FOUND');
  
  // If contracts not found via getDeployedContract, try to attach from config addresses
  if (!loopToken || !poolHelper || !vaultRegistry) {
    console.log('Some contracts not found via getDeployedContract. Trying to load from config...');
    
    const loopTokenAddr = CONFIG_NETWORK.Core.LoopToken;
    const poolHelperAddr = CONFIG_NETWORK.Core.BalancerPoolHelper;
    const vaultRegistryAddr = CONFIG_NETWORK.Core.VaultRegistry;
    
    console.log('Config addresses:');
    console.log('- LoopToken config:', loopTokenAddr);
    console.log('- BalancerPoolHelper config:', poolHelperAddr);
    console.log('- VaultRegistry config:', vaultRegistryAddr);
    
    // Try to attach contracts using config addresses
    if (!loopToken && loopTokenAddr) {
      console.log('Attaching LoopToken from config address...');
      loopToken = await attachContract('ERC20PresetMinterPauser', loopTokenAddr);
    }
    
    if (!poolHelper && poolHelperAddr) {
      console.log('Attaching BalancerPoolHelper from config address...');
      poolHelper = await attachContract('BalancerPoolHelper', poolHelperAddr);
    }
    
    if (!vaultRegistry && vaultRegistryAddr) {
      console.log('Attaching VaultRegistry from config address...');
      vaultRegistry = await attachContract('VaultRegistry', vaultRegistryAddr);
    }
    
    console.log('After attaching from config:');
    console.log('- LoopToken:', loopToken ? loopToken.address : 'STILL NOT FOUND');
    console.log('- BalancerPoolHelper:', poolHelper ? poolHelper.address : 'STILL NOT FOUND');
    console.log('- VaultRegistry:', vaultRegistry ? vaultRegistry.address : 'STILL NOT FOUND');
  }
  
  if (!loopToken || !poolHelper || !vaultRegistry) {
    throw new Error('Loop Token, Pool Helper, and Vault Registry must be deployed first');
  }

  const signer = await getSignerAddress();
  
  // Get configuration values from config
  const rewardConfig = CONFIG_NETWORK.Rewards;

  // Get addresses from config (using deployer as fallback for governance addresses)
  const lockZap = CONFIG_NETWORK.Core.LockZap === "deployer" ? signer : CONFIG_NETWORK.Core.LockZap;
  const dao = CONFIG_NETWORK.Core.DAO === "deployer" ? signer : CONFIG_NETWORK.Core.DAO;
  // Handle treasury - if it's a config object, use DAO address as treasury for now
  const treasury = (typeof CONFIG_NETWORK.Core.Treasury === 'object') ? dao : 
                   (CONFIG_NETWORK.Core.Treasury === "deployer" ? signer : CONFIG_NETWORK.Core.Treasury);

  console.log('Deploying reward contracts with configuration:');
  console.log('- Loop Token:', loopToken.address);
  console.log('- Lock Zap:', lockZap);
  console.log('- DAO:', dao);
  console.log('- Treasury:', treasury);
  console.log('- Rewards Duration:', rewardConfig.rewardsDuration / (24 * 60 * 60), 'days');
  console.log('- Rewards Per Second:', fromWad(rewardConfig.rewardsPerSecond));

  // Deploy PriceProvider (Mock for now)
  const priceProvider = await deployContract(
    'src/test/MockPriceProvider.sol:MockPriceProvider',
    'PriceProvider',
    false
  );

  console.log('PriceProvider deployed at:', priceProvider.address);

  // 1. Deploy MultiFeeDistribution
  const multiFeeDistributionImpl = await deployContract(
    'MultiFeeDistribution',
    'MultiFeeDistribution_Impl',
    false
  );

  const multiFeeDistributionProxy = await ethers.getContractFactory('ERC1967Proxy');
  const mfdInitData = multiFeeDistributionImpl.interface.encodeFunctionData('initialize', [
    loopToken.address,
    lockZap,
    dao,
    priceProvider.address,
    rewardConfig.rewardsDuration,
    rewardConfig.rewardsLookback,
    rewardConfig.lockDuration,
    rewardConfig.burnRatio,
    rewardConfig.vestDuration
  ]);

  const mfdProxy = await multiFeeDistributionProxy.deploy(
    multiFeeDistributionImpl.address,
    mfdInitData
  );
  await mfdProxy.deployed();

  const multiFeeDistribution = await ethers.getContractAt('MultiFeeDistribution', mfdProxy.address);

  await storeContractDeployment(
    false,
    'MultiFeeDistribution',
    multiFeeDistribution.address,
    'ERC1967Proxy',
    [multiFeeDistributionImpl.address, mfdInitData],
    {
      proxyType: 'ERC1967Proxy',
      implementation: multiFeeDistributionImpl.address
    }
  );

  console.log('MultiFeeDistribution deployed at:', multiFeeDistribution.address);

  // 2. Deploy EligibilityDataProvider
  const eligibilityDataProviderImpl = await deployContract(
    'EligibilityDataProvider',
    'EligibilityDataProvider_Impl',
    false
  );

  const edpProxy = await ethers.getContractFactory('ERC1967Proxy');
  const edpInitData = eligibilityDataProviderImpl.interface.encodeFunctionData('initialize', [
    vaultRegistry.address,
    multiFeeDistribution.address,
    priceProvider.address
  ]);

  const edpProxyContract = await edpProxy.deploy(
    eligibilityDataProviderImpl.address,
    edpInitData
  );
  await edpProxyContract.deployed();

  const eligibilityDataProvider = await ethers.getContractAt('EligibilityDataProvider', edpProxyContract.address);

  await storeContractDeployment(
    false,
    'EligibilityDataProvider',
    eligibilityDataProvider.address,
    'ERC1967Proxy',
    [eligibilityDataProviderImpl.address, edpInitData],
    {
      proxyType: 'ERC1967Proxy',
      implementation: eligibilityDataProviderImpl.address
    }
  );

  console.log('EligibilityDataProvider deployed at:', eligibilityDataProvider.address);

  // 3. Deploy ChefIncentivesController
  const chefIncentivesControllerImpl = await deployContract(
    'ChefIncentivesController',
    'ChefIncentivesController_Impl',
    false
  );

  const cicProxy = await ethers.getContractFactory('ERC1967Proxy');
  const cicInitData = chefIncentivesControllerImpl.interface.encodeFunctionData('initialize', [
    signer, // admin
    eligibilityDataProvider.address,
    multiFeeDistribution.address,
    rewardConfig.rewardsPerSecond,
    loopToken.address,
    rewardConfig.endingTimeCadence
  ]);

  const cicProxyContract = await cicProxy.deploy(
    chefIncentivesControllerImpl.address,
    cicInitData
  );
  await cicProxyContract.deployed();

  const chefIncentivesController = await ethers.getContractAt('ChefIncentivesController', cicProxyContract.address);

  await storeContractDeployment(
    false,
    'ChefIncentivesController',
    chefIncentivesController.address,
    'ERC1967Proxy',
    [chefIncentivesControllerImpl.address, cicInitData],
    {
      proxyType: 'ERC1967Proxy',
      implementation: chefIncentivesControllerImpl.address
    }
  );

  console.log('ChefIncentivesController deployed at:', chefIncentivesController.address);

  // 4. Configure the contracts
  console.log('Configuring reward contracts...');

  // Configure MultiFeeDistribution
  const lockDurations = rewardConfig.lockDurations;
  const rewardMultipliers = rewardConfig.rewardMultipliers;

  await multiFeeDistribution.setLockTypeInfo(lockDurations, rewardMultipliers);
  await multiFeeDistribution.setAddresses(chefIncentivesController.address, treasury);
  
  // Set LP token address from pool helper
  const lpTokenAddress = await poolHelper.lpTokenAddr();
  if (lpTokenAddress !== ethers.constants.AddressZero) {
    await multiFeeDistribution.setLPToken(lpTokenAddress);
    console.log('Set LP Token address:', lpTokenAddress);
  }

  // Set minters (ChefIncentivesController)
  await multiFeeDistribution.setMinters([chefIncentivesController.address]);

  // Configure EligibilityDataProvider
  await eligibilityDataProvider.setChefIncentivesController(chefIncentivesController.address);

  // Start the ChefIncentivesController
  await chefIncentivesController.start();

  console.log('Reward contracts configuration completed!');
  
  return {
    loopToken,
    poolHelper,
    priceProvider,
    multiFeeDistribution,
    eligibilityDataProvider,
    chefIncentivesController
  };
}

// Function to deploy position actions with tokenomics support
async function deployPositionActionsWithTokenomics(
  flashlender,
  swapAction,
  poolAction,
  vaultRegistry,
  poolType,
  config,
  loopToken,
  multiFeeDistribution,
  poolHelper
) {
  console.log('Deploying position actions with 8-parameter constructor...');

  const positionActions = [
    'PositionAction20',
    'PositionAction4626',
    'PositionActionPendle',
    'PositionActionTranchess',
    'PositionActionPenpie'
  ];

  for (const action of positionActions) {
    console.log(`Deploying ${action}...`);
    
    const args = [
      flashlender.address,              // flashlender_
      swapAction.address,               // swapAction_
      poolAction.address,               // poolAction_
      vaultRegistry.address,            // vaultRegistry_
      config.Core.WETH,                 // weth_
      multiFeeDistribution.address,     // multiFeeDistribution_
      loopToken.address,                // loopToken_
      poolHelper.address                // poolHelper_
    ];

    // Add PenpieHelper for PositionActionPenpie
    if (action === 'PositionActionPenpie') {
      args.push(config.Core.PenpieHelper);
    }

    await deployContract(
      action,
      `${action}_${poolType}`,
      false,
      ...args
    );

    console.log(`✅ ${action} deployed successfully`);
  }

  console.log('All position actions deployed with tokenomics support!');
}

// Function to grant zapper roles to all position actions
async function grantZapperRolesToPositionActions(poolHelper) {
  console.log('Granting zapper roles to position actions...');

  const positionActions = [
    'PositionAction20',
    'PositionAction4626', 
    'PositionActionPendle',
    'PositionActionTranchess',
    'PositionActionPenpie'
  ];

  for (const actionName of positionActions) {
    try {
      const positionAction = await getDeployedContract(`${actionName}_eth`);
      if (positionAction) {
        console.log(`Granting zapper role to ${actionName} at ${positionAction.address}`);
        await poolHelper.grantZapperRole(positionAction.address);
        console.log(`✅ Granted zapper role to ${actionName}`);
      } else {
        console.log(`⚠️  Could not find deployed ${actionName}`);
      }
    } catch (error) {
      console.error(`❌ Failed to grant zapper role to ${actionName}:`, error.message);
    }
  }

  console.log('Zapper role granting completed!');
}

// Function to setup reward pools for existing vaults
async function setupRewardPools(deployedContracts = null) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                   SETTING UP REWARD POOLS
//////////////////////////////////////////////////////////////*/
  `);

  let chefIncentivesController;
  
  // If contracts are passed as parameters, use them
  if (deployedContracts && deployedContracts.chefIncentivesController) {
    chefIncentivesController = deployedContracts.chefIncentivesController;
  } else {
    // Try to get from deployment files
    chefIncentivesController = await getDeployedContract('ChefIncentivesController');
  }
  
  if (!chefIncentivesController) {
    throw new Error('ChefIncentivesController must be deployed first');
  }

  console.log('Using ChefIncentivesController at:', chefIncentivesController.address);

  // Load deployed vaults
  const deployedVaults = await loadDeployedVaults();
  
  for (const [vaultName, vaultInfo] of Object.entries(deployedVaults)) {
    console.log(`Setting up rewards for vault: ${vaultName} at ${vaultInfo.address}`);
    
    const allocPoint = 100; // Default allocation points
    await chefIncentivesController.addPool(vaultInfo.address, allocPoint);
    
    // Set reward controller on vault
    const vault = await ethers.getContractAt('CDPVault', vaultInfo.address);
    await vault["setParameter(bytes32,address)"](toBytes32("rewardController"), chefIncentivesController.address);
    
    console.log(`- Added pool with ${allocPoint} allocation points`);
    console.log(`- Set reward controller on vault`);
  }
  
  console.log('Reward pools setup completed!');
}

// Function to deploy only VaultRegistry and add existing vaults
async function deployVaultRegistryOnly() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                    DEPLOYING VAULT REGISTRY ONLY
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy new VaultRegistry
  console.log('Deploying new VaultRegistry...');
  const vaultRegistry = await deployContract(
    'VaultRegistry',
    'VaultRegistry',
    false
  );
  console.log('VaultRegistry deployed at:', vaultRegistry.address);

  // Re-add all existing vaults to the new registry
  console.log('Adding existing vaults to new registry...');
  const deployedVaults = await loadDeployedVaults();
  
  for (const [vaultName, vaultInfo] of Object.entries(deployedVaults)) {
    console.log(`Adding vault: ${vaultName} at ${vaultInfo.address}`);
    await vaultRegistry.addVault(vaultInfo.address);
    console.log(`- Added ${vaultName} to registry`);
  }

  // Update config with VaultRegistry address
  CONFIG_NETWORK.Core.VaultRegistry = vaultRegistry.address;
  console.log('Updated config with VaultRegistry address:', vaultRegistry.address);

  return vaultRegistry;
}

// Function to deploy only position actions (using existing VaultRegistry)
async function redeployPositionActionsOnly(deployedContracts = null) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                REDEPLOYING POSITION ACTIONS ONLY
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();
  const poolType = 'eth';

  let loopToken, poolHelper, multiFeeDistribution, vaultRegistry;

  // If contracts are passed as parameters, use them
  if (deployedContracts) {
    loopToken = deployedContracts.loopToken;
    poolHelper = deployedContracts.poolHelper;
    multiFeeDistribution = deployedContracts.multiFeeDistribution;
    vaultRegistry = deployedContracts.vaultRegistry;
  } else {
    // Try to get from deployment files
    loopToken = await getDeployedContract('LoopToken');
    poolHelper = await getDeployedContract('BalancerPoolHelper');
    multiFeeDistribution = await getDeployedContract('MultiFeeDistribution');
    vaultRegistry = await getDeployedContract('VaultRegistry');
  }
  
  console.log('Contract validation:');
  console.log('- LoopToken:', loopToken ? loopToken.address : 'MISSING');
  console.log('- BalancerPoolHelper:', poolHelper ? poolHelper.address : 'MISSING');
  console.log('- MultiFeeDistribution:', multiFeeDistribution ? multiFeeDistribution.address : 'MISSING');
  console.log('- VaultRegistry:', vaultRegistry ? vaultRegistry.address : 'MISSING');

  if (!loopToken || !poolHelper || !multiFeeDistribution || !vaultRegistry) {
    const missing = [];
    if (!loopToken) missing.push('LoopToken');
    if (!poolHelper) missing.push('BalancerPoolHelper');
    if (!multiFeeDistribution) missing.push('MultiFeeDistribution');
    if (!vaultRegistry) missing.push('VaultRegistry');
    throw new Error(`Missing tokenomics contracts: ${missing.join(', ')}`);
  }

  // Update CONFIG_NETWORK with tokenomics contract addresses
  console.log('Updating config with tokenomics contract addresses...');
  CONFIG_NETWORK.Core.LoopToken = loopToken.address;
  CONFIG_NETWORK.Core.BalancerPoolHelper = poolHelper.address;
  CONFIG_NETWORK.Core.MultiFeeDistribution = multiFeeDistribution.address;
  CONFIG_NETWORK.Core.VaultRegistry = vaultRegistry.address;

  console.log('Updated config with:');
  console.log('- LoopToken:', loopToken.address);
  console.log('- BalancerPoolHelper:', poolHelper.address);
  console.log('- MultiFeeDistribution:', multiFeeDistribution.address);
  console.log('- VaultRegistry:', vaultRegistry.address);

  // Get existing action contracts
  const flashlender = await attachContract('Flashlender', CONFIG_NETWORK.Core.FlashlenderLPEth);
  const swapAction = await getDeployedContract(`SwapAction_${poolType}`);
  const poolAction = await getDeployedContract(`PoolAction_${poolType}`);

  if (!swapAction || !poolAction) {
    throw new Error('SwapAction and PoolAction must be deployed first. Please run full deployment.');
  }

  console.log('Using existing action contracts:');
  console.log('- SwapAction:', swapAction.address);
  console.log('- PoolAction:', poolAction.address);
  console.log('- Flashlender:', flashlender.address);

  // Deploy position actions with tokenomics support
  console.log('Deploying position actions with tokenomics support...');
  await deployPositionActionsWithTokenomics(
    flashlender, 
    swapAction, 
    poolAction, 
    vaultRegistry, 
    poolType, 
    CONFIG_NETWORK,
    loopToken,
    multiFeeDistribution,
    poolHelper
  );

  // Grant zapper roles to all position actions
  console.log('Granting zapper roles to position actions...');
  await grantZapperRolesToPositionActions(poolHelper);

  console.log('Position actions redeployment completed!');
  
  return {
    loopToken,
    poolHelper,
    multiFeeDistribution,
    vaultRegistry
  };
}

// Function to redeploy vault registry and position actions with tokenomics support
async function redeployVaultRegistryAndPositionActions() {
  console.log(`
/*//////////////////////////////////////////////////////////////
           REDEPLOYING VAULT REGISTRY & POSITION ACTIONS
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();
  const poolType = 'eth';

  // 1. Deploy new VaultRegistry
  console.log('Deploying new VaultRegistry...');
  const vaultRegistry = await deployContract(
    'VaultRegistry',
    'VaultRegistry',
    false
  );
  console.log('VaultRegistry deployed at:', vaultRegistry.address);

  // 2. Re-add all existing vaults to the new registry
  console.log('Adding existing vaults to new registry...');
  const deployedVaults = await loadDeployedVaults();
  
  for (const [vaultName, vaultInfo] of Object.entries(deployedVaults)) {
    console.log(`Adding vault: ${vaultName} at ${vaultInfo.address}`);
    await vaultRegistry.addVault(vaultInfo.address);
    console.log(`- Added ${vaultName} to registry`);
  }

  // 3. Get required contracts for position actions
  const loopToken = await getDeployedContract('LoopToken');
  const poolHelper = await getDeployedContract('BalancerPoolHelper');
  const multiFeeDistribution = await getDeployedContract('MultiFeeDistribution');
  
  if (!loopToken || !poolHelper || !multiFeeDistribution) {
    throw new Error('Tokenomics contracts (LoopToken, BalancerPoolHelper, MultiFeeDistribution) must be deployed first');
  }

  // 4. Update CONFIG_NETWORK with tokenomics contract addresses
  console.log('Updating config with tokenomics contract addresses...');
  CONFIG_NETWORK.Core.LoopToken = loopToken.address;
  CONFIG_NETWORK.Core.BalancerPoolHelper = poolHelper.address;
  CONFIG_NETWORK.Core.MultiFeeDistribution = multiFeeDistribution.address;
  CONFIG_NETWORK.Core.VaultRegistry = vaultRegistry.address;

  console.log('Updated config with:');
  console.log('- LoopToken:', loopToken.address);
  console.log('- BalancerPoolHelper:', poolHelper.address);
  console.log('- MultiFeeDistribution:', multiFeeDistribution.address);
  console.log('- VaultRegistry:', vaultRegistry.address);

  // 5. Get flashlender
  const flashlender = await attachContract('Flashlender', CONFIG_NETWORK.Core.FlashlenderLPEth);

  // 6. Use existing deployActions function with updated config
  console.log('Deploying actions with tokenomics support using deployActions...');
  await deployActions(CONFIG_NETWORK, poolType);

  // 7. Grant zapper roles to all position actions
  console.log('Granting zapper roles to position actions...');
  await grantZapperRolesToPositionActions(poolHelper);

  console.log('Vault registry and position actions redeployment completed!');
  
  return {
    vaultRegistry,
    loopToken,
    poolHelper,
    multiFeeDistribution
  };
}

// Function to deploy all tokenomics contracts in correct order  
async function deployCompleteTokenomicsSystem() {
  console.log(`
/*//////////////////////////////////////////////////////////////
              DEPLOYING COMPLETE TOKENOMICS SYSTEM
//////////////////////////////////////////////////////////////*/
  `);

  try {
    // Step 1: Deploy core tokenomics contracts
    console.log('Step 1: Deploying core tokenomics contracts...');
    const loopToken = await deployLoopToken();
    const poolHelper = await deployLiquidityPool();

    // Step 1.5: Deploy VaultRegistry first (needed for reward contracts)
    console.log('Step 1.5: Deploying VaultRegistry...');
    const vaultRegistry = await deployVaultRegistryOnly();

    // Step 1.6: Deploy reward contracts (now that VaultRegistry exists)
    console.log('Step 1.6: Deploying reward contracts...');
    const rewardContracts = await deployRewardContracts();

    // Collect all deployed contracts
    const deployedContracts = {
      loopToken,
      poolHelper,
      vaultRegistry,
      multiFeeDistribution: rewardContracts.multiFeeDistribution,
      eligibilityDataProvider: rewardContracts.eligibilityDataProvider,
      chefIncentivesController: rewardContracts.chefIncentivesController
    };

    // Step 2: Redeploy position actions with tokenomics support (reuse existing VaultRegistry)
    console.log('Step 2: Redeploying position actions with tokenomics support...');
    await redeployPositionActionsOnly(deployedContracts);

    // Step 3: Setup reward pools for existing vaults
    console.log('Step 3: Setting up reward pools...');
    await setupRewardPools(deployedContracts);

    console.log('✅ Complete tokenomics system deployment successful!');
    
  } catch (error) {
    console.error('❌ Tokenomics system deployment failed:', error);
    throw error;
  }
}

// Function to store pool information as a separate field in deployment file
async function storePoolInformation(poolHelper, lpTokenAddress, poolId, poolConfig, wethAmount, loopAmount, isManual = false) {
  console.log('📝 Storing pool information in deployment file...');
  
  const deploymentFilePath = path.join(__dirname, `deployment-${hre.network.name}.json`);
  
  let deployment = {};
  if (fs.existsSync(deploymentFilePath)) {
    deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  }
  
  // Store pool information as a separate field
  deployment.BalancerPool = {
    poolHelperAddress: poolHelper.address,
    lpTokenAddress: lpTokenAddress,
    poolId: poolId,
    poolName: poolConfig.poolName,
    poolSymbol: poolConfig.poolSymbol,
    balancerVault: CONFIG_NETWORK.Core.BalancerVault,
    poolFactory: CONFIG_NETWORK.Core.WeightedPoolFactory,
    tokens: {
      weth: CONFIG_NETWORK.Core.WETH,
      loop: CONFIG_NETWORK.Core.LoopToken || "TBD"
    },
    weights: {
      wethWeight: '200000000000000000', // 20%
      loopWeight: '800000000000000000'  // 80%
    },
    initialLiquidity: {
      wethAmount: wethAmount.toString(),
      loopAmount: loopAmount.toString(),
      formattedWethAmount: fromWad(wethAmount),
      formattedLoopAmount: fromWad(loopAmount)
    },
    deploymentInfo: {
      deploymentMethod: isManual ? 'manual' : 'automatic',
      deployedAt: new Date().toISOString(),
      timestamp: Math.floor(Date.now() / 1000),
      networkName: hre.network.name,
      chainId: hre.network.config.chainId
    }
  };
  
  fs.writeFileSync(deploymentFilePath, JSON.stringify(deployment, null, 2));
  console.log('✅ Pool information stored successfully');
  console.log(`   📍 Pool ID: ${poolId}`);
  console.log(`   🪙  LP Token: ${lpTokenAddress}`);
  console.log(`   📊 Pool Name: ${poolConfig.poolName}`);
  console.log(`   💧 Initial WETH: ${fromWad(wethAmount)}`);
  console.log(`   🔄 Initial LOOP: ${fromWad(loopAmount)}`);
}

// Function to show local deployment summary
function showLocalDeploymentSummary() {
  if (!isLocalNetwork()) return;
  
  console.log(`
/*//////////////////////////////////////////////////////////////
                    LOCAL DEPLOYMENT SUMMARY
//////////////////////////////////////////////////////////////*/
  `);
  
  console.log('🏠 LOCAL NETWORK DETECTED');
  console.log('- Network:', hre.network.name);
  console.log('- Chain ID:', hre.network.config.chainId || 'unknown');
  console.log('');
  console.log('✨ Special local network features enabled:');
  console.log('- ✅ Automatic ETH funding for deployer');
  console.log('- ✅ Automatic Loop token minting');
  console.log('- ✅ WETH wrapping for pool initialization');
  console.log('- ✅ Token transfers to pool helper');
  console.log('');
  console.log('📋 This ensures seamless pool deployment without manual token setup!');
  console.log('');
}

// Main execution function
((async () => {
  try {
    // Show local deployment summary if on anvil
    showLocalDeploymentSummary();
    
    // Initialize deployment with impersonation
    // uncomment this to deploy as the impersonated account, only supported on local deployment(anvil)
    // await impersonateDeployer();

    await deployCompleteTokenomicsSystem();
    
    // Alternative deployment options:
    // await deployLoopToken();
    // await deployLiquidityPool();
    // await initializePoolManually(); // Manual pool initialization (if not done during deployLiquidityPool)
    // await deployRewardContracts();
    // await redeployVaultRegistryAndPositionActions(); // Redeploy with tokenomics support
    // await setupRewardPools(); // Connect vaults to reward system
    
    // await redeployVaultRegistryAndPositionActions();
    // await setupRewardPools();

    // Core deployment options:
    // await deployCore();
    // await deployVaults();
    // await registerVaults(CONFIG_NETWORK);
    // await deployGauge(CONFIG_NETWORK.Core.PoolV3_LpETH, CONFIG_NETWORK, false);
    
    // Finalize and clean up if needed
    // await finalizeDeployment();
  } catch (error) {
    console.error("Deployment failed:", error);
    
    process.exit(1);
  }
})()).catch((error) => {
  console.error(error);
  process.exit(1);
});
