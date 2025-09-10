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
const CONFIG_TYPE = 'bitlayer';

// Load the network-specific and/or token-specific config
const CONFIG_NETWORK = loadConfig(CONFIG_TYPE);

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);
const toWad = ethers.utils.parseEther;
const fromWad = ethers.utils.formatEther;

/*//////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
//////////////////////////////////////////////////////////////*/

async function impersonateDeployer() {
  // For local testing, impersonate a specific account
  const accountToImpersonate = '0x9B2205E4E62e333141117Fc895DC77B558E2a2BC';
  
  // Fund the account with native token (BTC on Bitlayer) for gas
  await hre.network.provider.send('hardhat_setBalance', [
    accountToImpersonate,
    '0x21E19E0C9BAB2400000', // 10000 BTC (in wei equivalent)
  ]);

  // Impersonate the account
  await impersonateAccount(accountToImpersonate);
  console.log(`Impersonating account: ${accountToImpersonate}`);

  // Set the signer to the impersonated account
  const signer = await ethers.getSigner(accountToImpersonate);
  console.log(`Signer address: ${signer.address}`);
  console.log(`Signer balance: ${fromWad(await signer.getBalance())} BTC`);

  return signer;
}

async function finalizeDeployment() {
  // Stop impersonating
  const accountToImpersonate = '0x9B2205E4E62e333141117Fc895DC77B558E2a2BC';
  await stopImpersonatingAccount(accountToImpersonate);
  console.log(`Stopped impersonating account: ${accountToImpersonate}`);
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

async function deployPool() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING POOLS
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy WBTC Pool
  console.log('\n--- Deploying WBTC Pool ---');
  const deployedPool = await deploySinglePool('Pool LpWBTC');
  
  console.log('WBTC Pool deployment completed successfully');
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
    false, // isVault = false for pools
    poolConfig.wrappedToken, // weth_ (using WBTC for gas payments)
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
  
  // Store the pool address in Core config for vault deployment
  CONFIG_NETWORK.Core.PoolV3_lpWBTC = pool.address;

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
  
  // Store PoolQuotaKeeperV3 address in config for gauge deployment
  CONFIG_NETWORK.Core.PoolQuotaKeeperV3 = poolQuotaKeeper.address;

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
  
  // Store GaugeV3 address in config for gauge deployment
  CONFIG_NETWORK.Core.GaugeV3 = gauge.address;

  // Deploy staking and locking contracts
  const { stakingLp, lockLp } = await deployStakingAndLockingLP(
    pool,
    poolConfig.symbol.replace('lp', '').toUpperCase() // poolType parameter (WBTC)
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

async function deployWBTCPoolCore(poolAddress, stakingAddress, lockingAddress) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                    DEPLOYING WBTC POOL AUXILIARY CONTRACTS
//////////////////////////////////////////////////////////////*/
  `);

  console.log(`Using deployed pool at: ${poolAddress}`);
  console.log(`Using deployed staking at: ${stakingAddress}`);
  console.log(`Using deployed locking at: ${lockingAddress}`);

  // Update the config with the deployed pool address so other functions can find it
  CONFIG_NETWORK.Core.PoolV3_lpWBTC = poolAddress;

  // Custom position actions list for Bitlayer
  const customPositionActions = [
    'PositionAction20',
    'PositionAction4626',
    'PositionActionPendle',
    'PositionActionTranchess'
    // Skip PositionActionPenpie - not available on Bitlayer
  ];

  // Deploy auxiliary contracts for WBTC pool
  // Deploy treasury, vault registry, flashlender, and actions
  // Staking and locking are already deployed as part of the pool deployment
  const deployedCore = await deployPoolCoreSelective(
    CONFIG_NETWORK, 
    'wbtc', // pool type
    'PoolV3_lpWBTC', // pool key from config (now populated)
    customPositionActions, // custom position actions
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
  
  // Store ProxyRegistry address in config for vault deployment
  if (deployedCore.proxyRegistry) {
    CONFIG_NETWORK.Core.ProxyRegistry = deployedCore.proxyRegistry.address;
    console.log('ProxyRegistry address stored in config:', deployedCore.proxyRegistry.address);
  }
  
  console.log('WBTC Pool auxiliary contracts deployment completed');
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
    console.log('Deploying vault:', vaultName);

    // Deploy oracle using the common function with PushOracle support
    const oracleAddress = await deployVaultOracle(key, config, {
      'PushOracle': async (key, config) => {
        // Deploy PushOracle for BLBTC
        const oracleConfig = config.oracle.deploymentArguments;
        console.log(`Deploying PushOracle for ${key}`);
        
        // Deploy PushOracle implementation
        const pushOracleImpl = await deployContract(
          'PushOracle',
          `PushOracle_Impl_${key}`,
          false
        );
        
        console.log(`PushOracle implementation deployed at: ${pushOracleImpl.address}`);
        
        // Deploy ERC1967Proxy for upgradeable PushOracle
        const initData = pushOracleImpl.interface.encodeFunctionData('initialize', [
          oracleConfig.admin === 'deployer' ? signer : oracleConfig.admin,
          oracleConfig.manager === 'deployer' ? signer : oracleConfig.manager
        ]);
        
        const pushOracleProxy = await deployContract(
          'ERC1967Proxy',
          `PushOracle_${key}`,
          false,
          pushOracleImpl.address,
          initData
        );
        
        console.log(`PushOracle proxy deployed at: ${pushOracleProxy.address}`);
        
        // Attach to the proxy with PushOracle interface
        const pushOracle = await ethers.getContractAt('PushOracle', pushOracleProxy.address);
        
        // Configure the oracle for BLBTC token
        const oracleTokenConfig = config.oracle.oracleConfig;
        await pushOracle.setOracleConfigs(
          [oracleTokenConfig.token],
          [{
            stalePeriod: oracleTokenConfig.stalePeriod,
            twapWindow: oracleTokenConfig.twapWindow,
            twapEnabled: oracleTokenConfig.twapEnabled
          }]
        );
        
        console.log(`PushOracle configured for token: ${oracleTokenConfig.token}`);
        
        // Grant PRICE_UPDATER_ROLE to deployer
        const PRICE_UPDATER_ROLE = await pushOracle.PRICE_UPDATER_ROLE();
        await pushOracle.grantRole(PRICE_UPDATER_ROLE, signer);
        console.log(`Granted PRICE_UPDATER_ROLE to deployer: ${signer}`);
        
        return pushOracleProxy.address;
      }
    });

    if (!oracleAddress) {
      console.log(`Failed to deploy oracle for ${key}, skipping vault deployment`);
      continue;
    }

    // Resolve pool address from config reference
    let poolAddress;
    if (config.poolAddress.startsWith('Pool')) {
      // It's a reference to a pool config key, resolve it
      poolAddress = CONFIG_NETWORK.Core[config.poolAddress];
    } else {
      poolAddress = config.poolAddress;
    }

    if (!poolAddress) {
      console.log(`Pool address not found for vault ${key}, skipping deployment`);
      continue;
    }

    const tokenAddress = config.token;
    const tokenScale = config.tokenScale;

    console.log(`Deploying ${vaultName} with:`);
    console.log(`  Pool: ${poolAddress}`);
    console.log(`  Oracle: ${oracleAddress}`);
    console.log(`  Token: ${tokenAddress}`);

    // Deploy CDPVault
    const cdpVault = await deployContract(
      'CDPVault',
      vaultName,
      true, // isVault = true
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
  
  console.log('Vaults deployment completed');
}

async function storeVaultMetadataForGauge() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                    STORING VAULT METADATA
//////////////////////////////////////////////////////////////*/
  `);

  // Load deployed vaults from the deployment file
  const deployedVaults = await loadDeployedVaults();
  console.log('Loaded deployed vaults:', Object.keys(deployedVaults));

  // Store metadata for each vault
  for (const [vaultName, vault] of Object.entries(deployedVaults)) {
    console.log(`Processing vault: ${vaultName}`);
    
    // Get vault config from CONFIG_NETWORK
    // Strip "CDPVault_" prefix to match config key
    const configKey = vaultName.replace('CDPVault_', '');
    const vaultConfig = CONFIG_NETWORK.Vaults[configKey];
    if (!vaultConfig) {
      console.log(`No config found for vault ${vaultName} (config key: ${configKey}), skipping metadata storage`);
      continue;
    }
    
    // Get the deployed WBTC pool address from deployment file
    const deploymentFilePath = await getDeploymentFilePath();
    const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
    const wbtcPoolAddress = deployment.pools?.['Pool LpWBTC']?.address || CONFIG_NETWORK.Core.PoolV3_lpWBTC;
    
    // Store metadata including pool address and quotas
    const metadata = {
      pool: wbtcPoolAddress, // Pool address this vault is associated with
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
    console.log('Starting Bitlayer deployment...');
    
    // For local testing, impersonate and fund the deployer account
    if (hre.network.name === 'local' || hre.network.name === 'localhost' || hre.network.name === 'bitlayer_local') {
      console.log('\n=== SETTING UP LOCAL DEPLOYER ===');
      await impersonateDeployer();
    }
    
    // Step 1: Deploy AddressProviderV3 with ACL and ContractsRegister if not exists
    console.log('\n=== STEP 1: DEPLOYING ADDRESS PROVIDER ===');
    let deployedCore;
    if (!CONFIG_NETWORK.Core.AddressProviderV3) {
      deployedCore = await deployAddressProvider();
      console.log('Core infrastructure deployed successfully');
    } else {
      deployedCore = {
        addressProvider: await attachContract('AddressProviderV3', CONFIG_NETWORK.Core.AddressProviderV3),
        acl: CONFIG_NETWORK.Core.ACL ? await attachContract('ACL', CONFIG_NETWORK.Core.ACL) : null,
        contractsRegister: CONFIG_NETWORK.Core.ContractsRegister ? await attachContract('ContractsRegister', CONFIG_NETWORK.Core.ContractsRegister) : null
      };
      console.log('Using existing AddressProviderV3 at:', deployedCore.addressProvider.address);
    }
    
    // Step 2: Deploy WBTC Pool with all components
    console.log('\n=== STEP 2: DEPLOYING WBTC POOL ===');
    const deployedPool = await deployPool();
    
    // Step 3: Deploy WBTC pool auxiliary contracts (treasury, vault registry, flashlender, actions)
    console.log('\n=== STEP 3: DEPLOYING WBTC POOL AUXILIARY CONTRACTS ===');
    const deployedAuxiliaryContracts = await deployWBTCPoolCore(deployedPool.pool.address, deployedPool.stakingLp.address, deployedPool.lockLp.address);
    
    // Step 4: Deploy vaults
    console.log('\n=== STEP 4: DEPLOYING VAULTS ===');
    await deployVaults();
    
    // Step 5: Store vault metadata (needed for gauge configuration)
    console.log('\n=== STEP 5: STORING VAULT METADATA ===');
    await storeVaultMetadataForGauge();
    
    // Step 6: Register vaults in the vault registry
    console.log('\n=== STEP 6: REGISTERING VAULTS ===');
    const tempConfig = { ...CONFIG_NETWORK };
    tempConfig.Core.VaultRegistry = deployedAuxiliaryContracts.vaultRegistry.address;
    await registerVaults(tempConfig);
    
    // Step 7: Configure gauge (set min/max rates for vaults)
    console.log('\n=== STEP 7: CONFIGURING GAUGE ===');
    await deployGauge(deployedPool.pool.address, CONFIG_NETWORK, true);
    
    console.log('\n🎉 Bitlayer deployment completed successfully!');
    console.log('\nDeployed contracts summary:');
    console.log('- ACL: ✅');
    console.log('- AddressProviderV3: ✅');
    console.log('- ContractsRegister: ✅');
    console.log('- WBTC Pool: ✅');
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
    console.log('- BLBTC Vault: ✅');
    console.log('- Gauge Configuration: ✅');
    
    console.log('\nCore Infrastructure:');
    console.log('ACL:', deployedCore.acl?.address || 'N/A');
    console.log('AddressProviderV3:', deployedCore.addressProvider.address);
    console.log('ContractsRegister:', deployedCore.contractsRegister?.address || 'N/A');
    console.log('\nPool Infrastructure:');
    console.log('Pool Address:', deployedPool.pool.address);
    console.log('Staking Address:', deployedPool.stakingLp.address);
    console.log('Locking Address:', deployedPool.lockLp.address);
    console.log('Treasury Address:', deployedAuxiliaryContracts.treasury?.address || 'N/A');
    console.log('Vault Registry Address:', deployedAuxiliaryContracts.vaultRegistry?.address || 'N/A');
    console.log('Flashlender Address:', deployedAuxiliaryContracts.flashlender?.address || 'N/A');
    
    // Cleanup for local testing
    if (hre.network.name === 'local' || hre.network.name === 'localhost' || hre.network.name === 'bitlayer_local') {
      console.log('\n=== CLEANING UP LOCAL DEPLOYER ===');
      await finalizeDeployment();
    }
    
  } catch (error) {
    console.error('❌ Error during Bitlayer deployment:', error);
    
    // Cleanup even on error for local testing
    if (hre.network.name === 'local' || hre.network.name === 'localhost' || hre.network.name === 'bitlayer_local') {
      try {
        await finalizeDeployment();
      } catch (cleanupError) {
        console.error('Error during cleanup:', cleanupError);
      }
    }
    
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
