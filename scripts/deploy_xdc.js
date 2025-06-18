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
  await deploySinglePool('Pool LpUSDC');
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

async function deployCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING CORE
//////////////////////////////////////////////////////////////*/
  `);

  // Pass CONFIG_NETWORK to deployPoolCore
  const deployedCore = await deployPoolCore(CONFIG_NETWORK, 'xdc');
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

async function main() {
  try {
    // Initialize deployment with account impersonation
    // const impersonatedSigner = await impersonateDeployer();
    
    // Deploy pools (XDC and USDC)
    await deployPool();
    
    // Deploy core contracts
    // const deployedCore = await deployCore();
    
    // // Finalize deployment
    // await finalizeDeployment();
    
    console.log('XDC deployment completed successfully!');
  } catch (error) {
    console.error('Error during XDC deployment:', error);
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