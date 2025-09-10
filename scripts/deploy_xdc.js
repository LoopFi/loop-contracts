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
  deployPoolCoreSelective,
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
const CONFIG_TYPE = 'xdc';

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

  // Address to impersonate - replace with actual XDC deployer address
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

async function deployPool() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING POOLS
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy USDC Pool
  console.log('\n--- Deploying USDC Pool ---');
  const deployedPool = await deploySinglePool('Pool LpUSDC');
  
  console.log('USDC Pool deployment completed successfully');
  return deployedPool;
}

async function deploySinglePool(poolKey) {
  // Get the pool config from CONFIG_NETWORK
  const poolConfig = CONFIG_NETWORK.Pools[poolKey];
  console.log(`Deploying pool: ${poolConfig.name} (${poolConfig.symbol})`);
  
  // Deploy the interest rate model first as it's required for pool deployment
  const interestRateModel = await deployContract(
    'LinearInterestRateModelV3',
    `LinearInterestRateModelV3_${poolConfig.symbol}`,
    false,
    poolConfig.interestRateModel.U_1,
    poolConfig.interestRateModel.U_2,
    poolConfig.interestRateModel.R_base,
    poolConfig.interestRateModel.R_slope1,
    poolConfig.interestRateModel.R_slope2,
    poolConfig.interestRateModel.R_slope3,
    false
  );

  console.log(`LinearInterestRateModelV3 for ${poolConfig.symbol} deployed at:`, interestRateModel.address);

  // Deploy the PoolV3 contract
  const pool = await deployContract(
    'PoolV3',
    `PoolV3_${poolConfig.symbol}`,
    true,
    poolConfig.wrappedToken, // weth_ (using WXDC for gas payments)
    CONFIG_NETWORK.Core.AddressProviderV3, // addressProvider_
    poolConfig.underlier, // underlyingToken_
    interestRateModel.address, // interestRateModel_
    ethers.constants.MaxUint256, // totalDebtLimit_ (no limit initially)
    poolConfig.name, // name_
    poolConfig.symbol // symbol_
  );

  console.log(`PoolV3 ${poolConfig.symbol} deployed at:`, pool.address);

  // Store the pool address in the config for future reference
  CONFIG_NETWORK.Pools[poolKey].poolAddress = pool.address;

  // Deploy and set up the pool quota keeper
  const poolQuotaKeeper = await deployContract(
    'PoolQuotaKeeperV3',
    `PoolQuotaKeeperV3_${poolConfig.symbol}`,
    false,
    pool.address // pool_
  );

  console.log(`PoolQuotaKeeperV3 for ${poolConfig.symbol} deployed at:`, poolQuotaKeeper.address);

  // Set the pool quota keeper in the pool
  await pool.setPoolQuotaKeeper(poolQuotaKeeper.address);
  console.log(`Pool quota keeper set in ${poolConfig.symbol} pool`);

  // Get current block timestamp
  const blockNumber = await ethers.provider.getBlockNumber();
  const block = await ethers.provider.getBlock(blockNumber);
  const blockTimestamp = block.timestamp;

  // Deploy LoopVoter (shared across pools or pool-specific depending on requirements)
  let voter;
  if (!CONFIG_NETWORK.Core.LoopVoter) {
    voter = await deployContract(
      'LoopVoter',
      `LoopVoter_${poolConfig.symbol}`,
      false,
      CONFIG_NETWORK.Core.AddressProviderV3, // addressProvider_
      blockTimestamp // block.timestamp
    );
    console.log('LoopVoter deployed at:', voter.address);
    CONFIG_NETWORK.Core.LoopVoter = voter.address;
  } else {
    voter = await attachContract('LoopVoter', CONFIG_NETWORK.Core.LoopVoter);
    console.log('Using existing LoopVoter at:', voter.address);
  }

  // Deploy GaugeV3 with voter
  const gauge = await deployContract(
    'GaugeV3',
    `GaugeV3_${poolConfig.symbol}`,
    false,
    pool.address, // pool_
    voter.address // voter_
  );

  console.log(`GaugeV3 for ${poolConfig.symbol} deployed at:`, gauge.address);

  // Set the gauge in the pool quota keeper
  await poolQuotaKeeper.setGauge(gauge.address);
  console.log(`Gauge set in ${poolConfig.symbol} pool quota keeper`);

  // Deploy staking and locking contracts
  const { stakingLp, lockLp } = await deployStakingAndLockingLP(
    pool,
    poolConfig.symbol.replace('lp', '').toUpperCase() // poolType parameter (XDC or USDC)
  );
  console.log(`Staking contract for ${poolConfig.symbol} deployed at:`, stakingLp.address);
  console.log(`Locking contract for ${poolConfig.symbol} deployed at:`, lockLp.address);

  // Set cooldown periods (7 days in seconds)
  const SEVEN_DAYS = 7 * 24 * 60 * 60;
  
  // Set cooldown duration for staking contract
  await stakingLp.setCooldownDuration(SEVEN_DAYS);
  console.log(`Set cooldown duration to 7 days for ${poolConfig.symbol} staking contract`);

  // Set cooldown period for locking contract
  await lockLp.setCooldownPeriod(SEVEN_DAYS);
  console.log(`Set cooldown period to 7 days for ${poolConfig.symbol} locking contract`);

  return {
    pool,
    interestRateModel,
    poolQuotaKeeper,
    voter,
    gauge,
    stakingLp,
    lockLp
  };
}

// deployCore function removed - using existing AddressProviderV3

async function deployUSDCPoolCore(poolAddress, stakingAddress, lockingAddress) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                    DEPLOYING USDC POOL AUXILIARY CONTRACTS
//////////////////////////////////////////////////////////////*/
  `);

  console.log(`Using deployed pool at: ${poolAddress}`);
  console.log(`Using deployed staking at: ${stakingAddress}`);
  console.log(`Using deployed locking at: ${lockingAddress}`);

  // Update the config with the deployed pool address so other functions can find it
  CONFIG_NETWORK.Core.PoolV3_lpUSDC = poolAddress;

  // Custom position actions list excluding PositionActionPenpie (not available on XDC)
  const customPositionActions = [
    'PositionAction20',
    'PositionAction4626',
    'PositionActionPendle',
    'PositionActionTranchess'
    // Skip PositionActionPenpie - not available on XDC
  ];

  // Deploy auxiliary contracts for USDC pool
  // Deploy treasury, vault registry, flashlender, and actions
  // Staking and locking are already deployed as part of the pool deployment
  const deployedCore = await deployPoolCoreSelective(
    CONFIG_NETWORK, 
    'usdc', // pool type
    'PoolV3_lpUSDC', // pool key from config (now populated)
    customPositionActions, // custom position actions excluding Penpie
    {
      skipStaking: true, // Already deployed with pool
      skipLocking: true, // Already deployed with pool
      skipTreasury: false, // Deploy treasury
      skipVaultRegistry: false, // Deploy vault registry
      skipActions: false, // Deploy flashlender, proxy registry, and position actions
      existingContracts: {
        // Use the deployed staking and locking contracts
        stakingLp: stakingAddress,
        lockLp: lockingAddress
      }
    }
  );
  
  console.log('USDC Pool auxiliary contracts deployment completed');
  return deployedCore;
}

async function deployVaults_UNUSED() {
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
      'ChainlinkOracle': async (key, config) => {
        // XDC-specific Chainlink oracle deployment logic
        const oracleConfig = config.oracle.deploymentArguments;
        const deployedOracle = await deployContract(
          config.oracle.type,
          config.oracle.type+'_'+key,
          false,
          ...Object.values(oracleConfig)
        );
        return deployedOracle.address;
      },
      'Oracle_scrvUSD': async (key, config) => {
        // Deploy AggregatorV3CurveScrvUSD oracle for scrvUSD
        const oracleConfig = config.oracle.deploymentArguments;
        console.log(`Deploying AggregatorV3CurveScrvUSD oracle for ${key}`);
        
        // Deploy the AggregatorV3CurveScrvUSD contract
        const curveOracle = await deployContract(
          'AggregatorV3CurveScrvUSD',
          `AggregatorV3CurveScrvUSD_${key}`,
          false,
          oracleConfig.curvePool,  // _pool
          oracleConfig.k,          // _k
          true,                    // _invert
          oracleConfig.scrvUSDRateXDC // _scrvUSDOracle
        );
        
        console.log(`AggregatorV3CurveScrvUSD deployed at: ${curveOracle.address}`);
        
        // Deploy ChainlinkOracle implementation
        const chainlinkOracleImpl = await deployContract(
          'ChainlinkOracle',
          `ChainlinkOracle_Impl_${key}`,
          false
        );
        
        console.log(`ChainlinkOracle implementation deployed at: ${chainlinkOracleImpl.address}`);
        
        // Deploy ERC1967Proxy for ChainlinkOracle
        const signer = await getSignerAddress();
        const ERC1967Proxy = await ethers.getContractFactory('ERC1967Proxy');
        
        // Create initialization data for the proxy
        const initData = chainlinkOracleImpl.interface.encodeFunctionData('initialize', [signer, signer]);
        
        // Deploy the proxy
        const proxy = await ERC1967Proxy.deploy(
          chainlinkOracleImpl.address,
          initData
        );
        await proxy.deployed();
        
        const chainlinkOracle = await ethers.getContractAt('ChainlinkOracle', proxy.address);
        
        console.log(`ChainlinkOracle proxy deployed at: ${chainlinkOracle.address}`);
        
        // Set up the oracle mapping
        const tokens = [config.token]; // scrvUSD token address
        const oracles = [{
          aggregator: curveOracle.address,
          stalePeriod: 1, // 1 second stale period (very fresh)
          aggregatorScale: ethers.utils.parseEther('1') // 1e18 scale
        }];
        
        await chainlinkOracle.setOracles(tokens, oracles);
        console.log(`Oracle configured for token ${config.token}`);
        
        return chainlinkOracle.address;
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
  }
}

async function deployInterestRateModel() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                    DEPLOYING INTEREST RATE MODEL
//////////////////////////////////////////////////////////////*/
  `);

  const LinearInterestRateModelV3 = await deployContract(
    'LinearInterestRateModelV3',
    'LinearInterestRateModelV3',
    false,
    CONFIG_NETWORK.Pools['Pool LpXDC'].interestRateModel.U_1,
    CONFIG_NETWORK.Pools['Pool LpXDC'].interestRateModel.U_2,
    CONFIG_NETWORK.Pools['Pool LpXDC'].interestRateModel.R_base,
    CONFIG_NETWORK.Pools['Pool LpXDC'].interestRateModel.R_slope1,
    CONFIG_NETWORK.Pools['Pool LpXDC'].interestRateModel.R_slope2,
    CONFIG_NETWORK.Pools['Pool LpXDC'].interestRateModel.R_slope3,
    false
  );

  console.log('LinearInterestRateModelV3 deployed at:', LinearInterestRateModelV3.address);
  return LinearInterestRateModelV3;
}

async function deployAddressProvider() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                    DEPLOYING ADDRESS PROVIDER
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy ACL first
  const acl = await deployContract(
    'ACL',
    'ACL',
    false
  );
  console.log('ACL deployed at:', acl.address);

  // Deploy AddressProviderV3
  const addressProvider = await deployContract(
    'AddressProviderV3',
    'AddressProviderV3',
    false,
    acl.address // acl_
  );
  console.log('AddressProviderV3 deployed at:', addressProvider.address);

  // Deploy ContractsRegister
  const contractsRegister = await deployContract(
    'ContractsRegister',
    'ContractsRegister',
    false,
    addressProvider.address // addressProvider_
  );
  console.log('ContractsRegister deployed at:', contractsRegister.address);

  // Register ContractsRegister in AddressProvider
  await addressProvider.setAddress(
    ethers.utils.formatBytes32String('CONTRACTS_REGISTER'),
    contractsRegister.address,
    false
  );
  console.log('ContractsRegister registered in AddressProvider');

  // Store the addresses in the config
  CONFIG_NETWORK.Core.ACL = acl.address;
  CONFIG_NETWORK.Core.AddressProviderV3 = addressProvider.address;
  CONFIG_NETWORK.Core.ContractsRegister = contractsRegister.address;

  return {
    acl,
    addressProvider,
    contractsRegister
  };
}
async function performTransactions() {
  const signer = await getSignerAddress();
  const poolAddress = "0x235e49CC709F9e262814795c00eabe73709ef8E2";
  const pool = await attachContract('PoolV3', poolAddress);
  await pool.setLock(false);
  console.log('Pool unlocked');
}

// Removed storeVaultMetadataForGauge - not needed for USDC pool only deployment
async function storeVaultMetadataForGauge_UNUSED() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                     STORING VAULT METADATA
//////////////////////////////////////////////////////////////*/
  `);
  
  // Load deployed vaults to get their addresses
  const deployedVaults = await loadDeployedVaults();
  
  for (const [vaultName, vault] of Object.entries(deployedVaults)) {
    // Find corresponding vault config
    const vaultKey = vaultName.replace('CDPVault_', '');
    const vaultConfig = CONFIG_NETWORK.Vaults[vaultKey];
    
    if (!vaultConfig) {
      console.log(`No config found for vault ${vaultName}, skipping metadata storage`);
      continue;
    }
    
    // Get the deployed USDC pool address from deployment file
    const deploymentFilePath = await getDeploymentFilePath();
    const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
    const usdcPoolAddress = deployment.pools?.['Pool LpUSDC']?.address || CONFIG_NETWORK.Core.PoolV3_lpUSDC;
    
    // Store metadata including pool address and quotas
    const metadata = {
      pool: usdcPoolAddress, // Pool address this vault is associated with
      quotas: vaultConfig.quotas, // Min and max rates from config
      tokenSymbol: vaultConfig.tokenSymbol,
      token: vaultConfig.token
    };
    
    await storeVaultMetadata(vault.address, metadata);
    console.log(`Stored metadata for vault ${vaultName} at ${vault.address}`);
    console.log(`  Pool: ${metadata.pool}`);
    console.log(`  Min Rate: ${metadata.quotas.minRate}`);
    console.log(`  Max Rate: ${metadata.quotas.maxRate}`);
  }
}

// deployPositionActionsForPool function removed - position actions are deployed as part of auxiliary contracts

async function main() {
  try {
    console.log('Starting USDC Pool deployment on XDC...');
    console.log('Using existing AddressProviderV3:', CONFIG_NETWORK.Core.AddressProviderV3);
    
    // Step 1: Deploy USDC Pool with all components (interest rate model, quota keeper, voter, gauge, staking, locking)
    console.log('\n=== STEP 1: DEPLOYING USDC POOL ===');
    const deployedPool = await deployPool();
    
    // Step 2: Deploy USDC pool auxiliary contracts (treasury, vault registry, flashlender, actions)
    console.log('\n=== STEP 2: DEPLOYING USDC POOL AUXILIARY CONTRACTS ===');
    const deployedAuxiliaryContracts = await deployUSDCPoolCore(deployedPool.pool.address, deployedPool.stakingLp.address, deployedPool.lockLp.address);
    
    // Position actions are already deployed as part of Step 2 (auxiliary contracts)
    
    console.log('\n🎉 USDC Pool deployment completed successfully!');
    console.log('\nDeployed contracts summary:');
    console.log('- USDC Pool: ✅');
    console.log('- Interest Rate Model: ✅');
    console.log('- Pool Quota Keeper: ✅');
    console.log('- Voter: ✅');
    console.log('- Gauge: ✅');
    console.log('- Staking Contract: ✅');
    console.log('- Locking Contract: ✅');
    console.log('- Treasury: ✅');
    console.log('- Vault Registry: ✅');
    console.log('- Flashlender: ✅');
    console.log('- Position Actions (4 types): ✅');
    
    console.log('\nPool Address:', deployedPool.pool.address);
    console.log('Staking Address:', deployedPool.stakingLp.address);
    console.log('Locking Address:', deployedPool.lockLp.address);
    console.log('Treasury Address:', deployedAuxiliaryContracts.treasury?.address || 'N/A');
    console.log('Vault Registry Address:', deployedAuxiliaryContracts.vaultRegistry?.address || 'N/A');
    console.log('Flashlender Address:', deployedAuxiliaryContracts.flashlender?.address || 'N/A');
    
  } catch (error) {
    console.error('❌ Error during USDC Pool deployment:', error);
    process.exit(1);
  }
}

// Execute the main function
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 