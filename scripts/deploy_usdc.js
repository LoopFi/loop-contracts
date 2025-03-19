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
  impersonateAccount,
  stopImpersonatingAccount,
} = require('./utils/deployUtils');
const { 
  getNetworkName, 
  loadConfig 
} = require('./utils/configUtils');

// Hardcode the config type for this specific deployment script
const CONFIG_TYPE = 'usdc';

// Load the network-specific and/or token-specific config
const CONFIG_NETWORK = loadConfig(CONFIG_TYPE);

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);
const toWad = ethers.utils.parseEther;
const fromWad = ethers.utils.formatEther;
const toBytes32 = ethers.utils.formatBytes32String;

// Add this helper function at the top level
function getPoolSpecificName(baseName, poolIdentifier = 'usdc') {
  return `${baseName}_${poolIdentifier}`;
}

async function deployCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING CORE
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();

  if (hre.network.name == 'tenderly') {
    await ethers.provider.send('tenderly_setBalance', [[signer], ethers.utils.hexValue(toWad('100').toHexString())]);
  }

  const addressProviderV3 = await attachContract('AddressProviderV3', CONFIG_NETWORK.Core.AddressProviderV3);
  console.log('AddressProviderV3 deployed to:', addressProviderV3.address);

  const pool = await attachContract('PoolV3', CONFIG_NETWORK.Core.PoolV3_LpUSD);
  console.log('PoolV3 deployed to:', pool.address);

  const { stakingLpUsdc, lockLpUsdc } = await deployStakingAndLockingLP(pool);
  console.log('StakingLPUsdc deployed to:', stakingLpUsdc.address);
  console.log('LockingLpUsdc deployed to:', lockLpUsdc.address);

  const treasuryReplaceParams = {
    'deployer': signer,
    'stakingLpUsdc': stakingLpUsdc.address
  };

  const { payees, shares, admin } = replaceParams(CONFIG_NETWORK.Core.Treasury.constructorArguments, treasuryReplaceParams);
  const treasury = await deployContract('Treasury', getPoolSpecificName('Treasury'), false, payees, shares, admin);
  console.log('Treasury deployed to:', treasury.address);
  
  await pool.setTreasury(treasury.address);

  // Deploy Vault Registry
  const vaultRegistry = await attachContract('VaultRegistry', CONFIG_NETWORK.Core.VaultRegistry);
  console.log('Vault Registry deployed to:', vaultRegistry.address);

  // Deploy actions with the vault registry
  const { flashlender, proxyRegistry } = await deployActions(pool, vaultRegistry);
  
  console.log('------------------------------------');
}

async function deployStakingAndLockingLP(pool) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                  DEPLOYING STAKING & LOCKING LP
//////////////////////////////////////////////////////////////*/
  `);

  const minShares = "10000"; // 0.01 * 10^6
  const stakingLpUsdc = await deployContract(
    'StakingLPEth', 
    getPoolSpecificName('StakingLPUsdc'),
    false, 
    pool.address, 
    "StakingLPUsdc", 
    "slpUSDC",
    minShares
  );
  console.log('StakingLPUsdc deployed to:', stakingLpUsdc.address);

  const lockLpUsdc = await deployContract(
    'Locking', 
    getPoolSpecificName('LockingLpUsdc'),
    false, 
    pool.address
  );
  console.log('lockLpUsdc deployed to:', lockLpUsdc.address);

  await verifyOnTenderly('stakingLpUsdc', stakingLpUsdc.address);
  await verifyOnTenderly('LockingLPEth', lockLpUsdc.address);

  return { stakingLpUsdc, lockLpUsdc };
}

async function deployActions(pool, vaultRegistry) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING ACTIONS
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy Flashlender with pool-specific name
  const flashlender = await deployContract(
    'Flashlender', 
    getPoolSpecificName('Flashlender'),
    false, 
    pool.address, 
    CONFIG_NETWORK.Core.Flashlender.constructorArguments.protocolFee_
  );
  
  const UINT256_MAX = ethers.constants.MaxUint256;
  await pool.setCreditManagerDebtLimit(flashlender.address, UINT256_MAX);
  console.log('Set credit manager debt limit for flashlender to max');
  
  // Deploy PRBProxyRegistry (this one doesn't need pool suffix as it's chain-wide)
  const proxyRegistry = await attachContract('PRBProxyRegistry', CONFIG_NETWORK.Core.PRBProxyRegistry);
  
  // Deploy Actions with pool-specific names
  const swapAction = await deployContract(
    'SwapAction', 
    getPoolSpecificName('SwapAction'),
    false, 
    ...Object.values(CONFIG_NETWORK.Core.Actions.SwapAction.constructorArguments)
  );
  
  const poolAction = await deployContract(
    'PoolAction', 
    getPoolSpecificName('PoolAction'),
    false, 
    ...Object.values(CONFIG_NETWORK.Core.Actions.PoolAction.constructorArguments)
  );

  // Deploy Position Actions with pool-specific names
  await deployContract(
    'PositionAction20', 
    getPoolSpecificName('PositionAction20'),
    false, 
    flashlender.address, 
    swapAction.address, 
    poolAction.address, 
    vaultRegistry.address, 
    CONFIG_NETWORK.Core.WETH
  );
  
  await deployContract(
    'PositionAction4626', 
    getPoolSpecificName('PositionAction4626'),
    false, 
    flashlender.address, 
    swapAction.address, 
    poolAction.address, 
    vaultRegistry.address, 
    CONFIG_NETWORK.Core.WETH
  );
  
  await deployContract(
    'PositionActionPendle', 
    getPoolSpecificName('PositionActionPendle'),
    false, 
    flashlender.address, 
    swapAction.address, 
    poolAction.address, 
    vaultRegistry.address, 
    CONFIG_NETWORK.Core.WETH
  );
  
  await deployContract(
    'PositionActionTranchess', 
    getPoolSpecificName('PositionActionTranchess'),
    false, 
    flashlender.address, 
    swapAction.address, 
    poolAction.address, 
    vaultRegistry.address, 
    CONFIG_NETWORK.Core.WETH
  );
  
  await deployContract(
    'PositionActionPenpie', 
    getPoolSpecificName('PositionActionPenpie'),
    false, 
    flashlender.address, 
    swapAction.address, 
    poolAction.address, 
    vaultRegistry.address, 
    CONFIG_NETWORK.Core.WETH, 
    CONFIG_NETWORK.Core.PenpieHelper
  );

  console.log('------------------------------------');

  return { flashlender, proxyRegistry, swapAction, poolAction };
}

async function deployGauge() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING GAUGE
//////////////////////////////////////////////////////////////*/
  `);

  const {
    AddressProviderV3: addressProviderV3,
  } = await loadDeployedContracts();

  const poolAddress = await getPoolAddress("LpUSD");
  if (poolAddress == undefined || poolAddress == null) {
    console.log('No pool address defined for gauge');
    return;
  }
  console.log('GAUGE POOL ADDRESS:', poolAddress);

  const liquidityPool = await attachContract('PoolV3', poolAddress);
  const latestBlock = await ethers.provider.getBlock('latest');
  const blockTimestamp = latestBlock.timestamp;
  const firstEpochTimestamp = blockTimestamp + 300; // Start 5 minutes from now
  
  const voter = await deployContract('LoopVoter', getPoolSpecificName('LoopVoter'), false, addressProviderV3.address, firstEpochTimestamp);
  console.log(`Voter deployed to: ${voter.address}`);

  // Deploy GaugeV3 contract
  const gaugeV3 = await deployContract(
    'GaugeV3', 
    getPoolSpecificName('GaugeV3'),
    false, 
    liquidityPool.address, 
    voter.address
  );
  console.log(`GaugeV3 deployed to: ${gaugeV3.address}`);
  
  // Assuming quotaKeeper and other necessary contracts are already deployed and their addresses are known
  const poolQuotaKeeperV3 = await deployContract(
    'PoolQuotaKeeperV3', 
    getPoolSpecificName('PoolQuotaKeeperV3'),
    false, 
    liquidityPool.address
  );
  await liquidityPool.setPoolQuotaKeeper(poolQuotaKeeperV3.address);

  // Set Gauge in QuotaKeeper
  await poolQuotaKeeperV3.setGauge(gaugeV3.address);
  console.log('Set gauge in QuotaKeeper');

  const { VaultRegistry: vaultRegistry } = await loadDeployedContracts()
  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    const vaultMetadata = await getVaultMetadata(vault.address);
    if (!vaultMetadata) {
      console.log(`No metadata found for vault: ${vault.address}`);
      continue;
    }

    if (vaultMetadata.pool.toLowerCase() != poolAddress.toLowerCase()) {
      console.log(`Vault ${vault.address} is not associated with pool ${poolAddress}`);
      continue;
    }

    const tokenAddress = await vault.token();
    await poolQuotaKeeperV3.setCreditManager(tokenAddress, vault.address);
    console.log('Set Credit Manager in QuotaKeeper for token:', tokenAddress);
    
    const minRate = vaultMetadata.quotas.minRate;
    const maxRate = vaultMetadata.quotas.maxRate;
    
    console.log('Setting quota rates for token:', tokenAddress, 'minRate:', minRate, 'maxRate:', maxRate);
    await gaugeV3.addQuotaToken(tokenAddress, minRate, maxRate);

    console.log('Added quota token to GaugeV3 for token:', tokenAddress);
  }

  // Unfreeze the epoch in Gauge
  await gaugeV3.setFrozenEpoch(false);
  console.log('Set frozen epoch to false in GaugeV3');

  //await quotaKeeper.updateRates();
  
  console.log('Gauge and related configurations have been set.');
}

async function deployGearboxCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING GEARBOX CORE
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy ACL contract
  const ACL = await deployContract('ACL', 'ACL', false);
  
  // Deploy AddressProviderV3 contract and set addresses
  const AddressProviderV3 = await deployContract('AddressProviderV3', 'AddressProviderV3', false, ACL.address);
  await AddressProviderV3.setAddress(toBytes32('WETH_TOKEN'), CONFIG_NETWORK.Core.WETH, false);

  // Deploy ContractsRegister and set its address in AddressProviderV3
  const ContractsRegister = await deployContract('ContractsRegister', 'ContractsRegister', false, AddressProviderV3.address);
  await AddressProviderV3.setAddress(toBytes32('CONTRACTS_REGISTER'), ContractsRegister.address, false);

  console.log('Gearbox Core Contracts Deployed');
  
  await verifyOnTenderly('ACL', ACL.address);
  
  await verifyOnTenderly('AddressProviderV3', AddressProviderV3.address);
  
  await verifyOnTenderly('ContractsRegister', ContractsRegister.address);

  return { ACL, AddressProviderV3, ContractsRegister };
}

async function deployPools(addressProviderV3) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING POOLS
//////////////////////////////////////////////////////////////*/
  `);

  const pools = [];
  
  for (const [poolKey, poolConfig] of Object.entries(CONFIG_NETWORK.Pools)) {
    // Deploy LinearInterestRateModelV3 for this pool
    const LinearInterestRateModelV3 = await deployContract(
      'LinearInterestRateModelV3',
      `LinearInterestRateModelV3_${poolKey}`,
      false,
      poolConfig.interestRateModel.U_1,
      poolConfig.interestRateModel.U_2,
      poolConfig.interestRateModel.R_base,
      poolConfig.interestRateModel.R_slope1,
      poolConfig.interestRateModel.R_slope2,
      poolConfig.interestRateModel.R_slope3,
      poolConfig.interestRateModel.isBorrowingMoreU2Forbidden || false
    );

    // Deploy PoolV3 contract
    const PoolV3 = await deployContract(
      'PoolV3',
      `PoolV3_${poolKey}`,
      false,
      poolConfig.wrappedToken,
      addressProviderV3.address,
      poolConfig.underlier,
      LinearInterestRateModelV3.address,
      poolConfig.initialDebtCeiling || CONFIG_NETWORK.Core.Gearbox.initialGlobalDebtCeiling,
      poolConfig.name,
      poolConfig.symbol
    );

    console.log(`Pool ${poolKey} Deployed at ${PoolV3.address}`);
    
    // Only verify on Tenderly, don't call storeContractDeployment again
    await verifyOnTenderly('LinearInterestRateModelV3', LinearInterestRateModelV3.address);
    await verifyOnTenderly('PoolV3', PoolV3.address);

    pools.push(PoolV3);
  }

  return pools;
}

async function deployGearbox() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING GEARBOX
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy LinearInterestRateModelV3 contract
  const LinearInterestRateModelV3 = await deployContract(
    'LinearInterestRateModelV3',
    'LinearInterestRateModelV3',
    false, // not a vault
    CONFIG_NETWORK.LinearInterestRateModelV3.U_1, // U_1
    CONFIG_NETWORK.LinearInterestRateModelV3.U_2, // U_2
    CONFIG_NETWORK.LinearInterestRateModelV3.R_base, // R_base
    CONFIG_NETWORK.LinearInterestRateModelV3.R_slope1, // R_slope1
    CONFIG_NETWORK.LinearInterestRateModelV3.R_slope2, // R_slope2
    CONFIG_NETWORK.LinearInterestRateModelV3.R_slope3, // R_slope3
    false // _isBorrowingMoreU2Forbidden
  );

  // Deploy ACL contract
  const ACL = await deployContract('ACL', 'ACL', false);
  const underlierAddress = CONFIG_NETWORK.Pools.LiquidityPool.underlier;

  // Deploy AddressProviderV3 contract and set addresses
  const AddressProviderV3 = await deployContract('AddressProviderV3', 'AddressProviderV3', false, ACL.address);
  await AddressProviderV3.setAddress(toBytes32('WETH_TOKEN'), underlierAddress, false);

  // Deploy ContractsRegister and set its address in AddressProviderV3
  const ContractsRegister = await deployContract('ContractsRegister', 'ContractsRegister', false, AddressProviderV3.address);
  await AddressProviderV3.setAddress(toBytes32('CONTRACTS_REGISTER'), ContractsRegister.address, false);

  // Deploy PoolV3 contract
  const PoolV3 = await deployContract(
    'PoolV3',
    'PoolV3',
    false, // not a vault
    CONFIG_NETWORK.Pools.LiquidityPool.wrappedToken, // wrapped native token
    AddressProviderV3.address, // addressProvider_
    underlierAddress, // underlyingToken_
    LinearInterestRateModelV3.address, // interestRateModel_
    CONFIG_NETWORK.Core.Gearbox.initialGlobalDebtCeiling, // Debt ceiling
    CONFIG_NETWORK.Pools.LiquidityPool.name, // name_
    CONFIG_NETWORK.Pools.LiquidityPool.symbol // symbol_
  );

  console.log('Gearbox Contracts Deployed');
  
  await verifyOnTenderly('LinearInterestRateModelV3', LinearInterestRateModelV3.address);
  await verifyOnTenderly('ACL', ACL.address);
  await verifyOnTenderly('AddressProviderV3', AddressProviderV3.address);
  await verifyOnTenderly('ContractsRegister', ContractsRegister.address);
  await verifyOnTenderly('PoolV3', PoolV3.address);

  return { PoolV3, AddressProviderV3 };
}

async function deployVaultOracle(key, config) {
  if (!config.oracle) {
    console.log('No oracle defined for', key);
    return null;
  }

  if(config.oracle.type == "WstUSR") {
    return await deployWstUSROracle(key, config);
  }

  if(config.oracle.type == "syrupUSDC") {
    return await deploySyrupUSDCOracle(key, config);
  }

  if (config.oracle.type == "deUSD") {
    return await deploydeUSDOracle(key, config);
  }

  if (config.oracle.type == "PendleLPOracle_sUSDe") {
    return await deploysUSDeOracle(key, config);
  }

  console.log('Deploying oracle for', key);
  const oracleConfig = config.oracle.deploymentArguments;
  const deployedOracle = await deployContract(
    config.oracle.type,
    config.oracle.type,
    false,
    ...Object.values(oracleConfig)
  );
  console.log(`Oracle deployed for ${key} at ${deployedOracle.address}`);
  return deployedOracle.address;
}

async function deploySyrupUSDCOracle(key, config) {
  console.log('Deploying syrupUSDC oracle for', key);
  const oracleConfig = config.oracle.deploymentArguments;

  // Deploy Combined4626AggregatorV3Oracle
  const aggregator4626 = await deployContract(
    'AggregatorV3Oracle4626',
    'AggregatorV3Oracle4626',
    false,
    oracleConfig.vault,
  );
  console.log(`AggregatorV3Oracle4626 deployed for ${key} at ${aggregator4626.address}`);

  // Deploy PendleLPOracle
  const pendleLPOracle = await deployContract(
    'PendleLPOracle',
    'PendleLPOracle',
    false,
    oracleConfig.ptOracle,
    oracleConfig.market,
    oracleConfig.twap,
    aggregator4626.address,
    oracleConfig.stalePeriod
  );
  console.log(`PendleLPOracle deployed for ${key} at ${pendleLPOracle.address}`);

  return pendleLPOracle.address;
}

async function deploydeUSDOracle(key, config) {
  console.log('Deploying deUSD oracle for', key);
  const oracleConfig = config.oracle.deploymentArguments;

  const combined4626AggregatorV3Oracle = await deployContract(
    'Combined4626AggregatorV3Oracle',
    'Combined4626AggregatorV3Oracle',
    false,
    oracleConfig.deUSDFeed,
    oracleConfig.heartbeat,
    oracleConfig.sdeUSDVault,
  );
  console.log(`Combined4626AggregatorV3Oracle deployed for ${key} at ${combined4626AggregatorV3Oracle.address}`);

  const combinedAggregatorV3Oracle = await deployContract(
    'CombinedAggregatorV3Oracle',
    'CombinedAggregatorV3Oracle',
    false,
    combined4626AggregatorV3Oracle.address,
    oracleConfig.heartbeat,
    oracleConfig.usdc_aggregator,
    oracleConfig.usdc_heartbeat,
    false
  );

  const chainlinkCurveOracle = await deployContract(
    'ChainlinkCurveOracle',
    'ChainlinkCurveOracle',
    false,
    combinedAggregatorV3Oracle.address,
    oracleConfig.curvePool,
    oracleConfig.stalePeriod
  );
  console.log(`ChainlinkCurveOracle deployed for ${key} at ${chainlinkCurveOracle.address}`);

  return chainlinkCurveOracle.address;
}

async function deploysUSDeOracle(key, config) {
  console.log('Deploying sUSDe oracle for', key);
  const oracleConfig = config.oracle.deploymentArguments;
  
  const CombinedAggregatorV3Oracle = await deployContract(
    'CombinedAggregatorV3Oracle',
    'CombinedAggregatorV3Oracle',
    false,
    oracleConfig.usde_aggregator,
    oracleConfig.usde_heartbeat,
    oracleConfig.usdc_aggregator,
    oracleConfig.usdc_heartbeat,
    false
  );
  console.log(`CombinedAggregatorV3Oracle deployed for ${key} at ${CombinedAggregatorV3Oracle.address}`);

  const PendleLPOracle = await deployContract(
    'PendleLPOracle',
    'PendleLPOracle',
    false,
    oracleConfig.ptOracle,
    oracleConfig.market,
    oracleConfig.twap,
    CombinedAggregatorV3Oracle.address,
    oracleConfig.usde_heartbeat
  );
  console.log(`PendleLPOracle deployed for ${key} at ${PendleLPOracle.address}`);

  return CombinedAggregatorV3Oracle.address;
}

async function deployWstUSROracle(key, config) {
  console.log('Deploying WstUSR oracle for', key);
  const oracleConfig = config.oracle.deploymentArguments;

  // Deploy PythAggregatorV3
  const pythAggregator = await deployContract(
    'PythAggregatorV3',
    'PythAggregatorV3',
    false,
    oracleConfig.pythPriceFeedsContract,
    oracleConfig.feedIdUSRUSD
  );
  console.log(`PythAggregatorV3 deployed for ${key} at ${pythAggregator.address}`);

  // Deploy CombinedAggregatorV3Oracle
  const combinedOracle = await deployContract(
    'CombinedAggregatorV3Oracle',
    'CombinedAggregatorV3Oracle',
    false,
    pythAggregator.address,
    3600, // heartbeat
    oracleConfig.chainlinkUSDCFeed,
    oracleConfig.usdcHeartbeat,
    false // invertPrice
  );
  console.log(`CombinedAggregatorV3Oracle deployed for ${key} at ${combinedOracle.address}`);

  // Deploy PendleLPOracle
  const pendleLPOracle = await deployContract(
    'PendleLPOracle',
    'PendleLPOracle',
    false,
    oracleConfig.ptOracle,
    oracleConfig.market,
    oracleConfig.twap,
    pythAggregator.address,
    oracleConfig.stalePeriod
  );
  console.log(`PendleLPOracle deployed for ${key} at ${pendleLPOracle.address}`);

  return pendleLPOracle.address;
}


async function deployVaults(pool) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING VAULTS
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();
  const {
    PRBProxyRegistry: prbProxyRegistry,
    ...contracts
  } = await loadDeployedContracts();
  
  for (const [key, config] of Object.entries(CONFIG_NETWORK.Vaults)) {
    const vaultName = `CDPVault_${key}`;
    console.log('deploying vault ', vaultName);

    // Deploy oracle using the new function
    const oracleAddress = await deployVaultOracle(key, config);
    if (!oracleAddress) return;

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
        false, // not a vault
        "MockCollateralToken", // name
        "MCT" // symbol
      );
      tokenAddress = token.address;
      tokenScale = new ethers.BigNumber.from(10).pow(await token.decimals());
      tokenSymbol = "MCT";
    }

    const poolAddress = await getPoolAddress(config.poolAddress);
    if (!poolAddress) {
      console.log(`ERROR: Could not find pool address for ${config.poolAddress}`);
      return;
    }

    // Verify this is actually a Pool contract
    try {
      const pool = await attachContract('PoolV3', poolAddress);
      // Call a method that only exists on PoolV3 to verify it's the right contract
      const underlyingToken = await pool.underlyingToken();
      console.log(`Verified pool at ${poolAddress} with underlying token: ${underlyingToken}`);
    } catch (error) {
      console.error(`ERROR: Address ${poolAddress} is not a valid PoolV3 contract:`, error.message);
      return;
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

/*//////////////////////////////////////////////////////////////
                        DEPLOYING REWARD CONTRACTS
//////////////////////////////////////////////////////////////*/

async function registerVaults() {
  const { VaultRegistry: vaultRegistry } = await loadDeployedContracts();
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  
  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    console.log(`${name}: ${vault.address}`);
    
    // Check if vault is already registered
    if (deployment.vaults[name] && !deployment.vaults[name].addedToRegistry) {
      await vaultRegistry.addVault(vault.address);
      console.log('Added', name, 'to vault registry');
      
      // Update the registry status
      deployment.vaults[name].addedToRegistry = true;
      fs.writeFileSync(deploymentFilePath, JSON.stringify(deployment, null, 2));
    } else {
      console.log(name, 'already registered, skipping');
    }
  }
}

async function logVaults() {
  const { CDM: cdm } = await loadDeployedContracts()
  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    console.log(`${name}: ${vault.address}`);
    console.log('  debtCeiling:', fromWad(await cdm.creditLine(vault.address)));
    const vaultConfig = await vault.vaultConfig();
    console.log('  debtFloor:', fromWad(vaultConfig.debtFloor));
    console.log('  liquidationRatio:', fromWad(vaultConfig.liquidationRatio));
    const liquidationConfig = await vault.liquidationConfig();
    console.log('  liquidationPenalty:', fromWad(liquidationConfig.liquidationPenalty));
    console.log('  liquidationDiscount:', fromWad(liquidationConfig.liquidationDiscount));
  }
}

async function deployPool() {
  const addressProviderV3Address = '0x9613E12A424B4CbaCF561F0ec54b418c76d6B26D';
  const addressProviderV3 = await attachContract('AddressProviderV3', addressProviderV3Address);
  const pools = await deployPools(addressProviderV3);
}

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
  const { signer, restore } = await impersonateAccount(accountToImpersonate);
  
  console.log(`Now deploying as impersonated account: ${accountToImpersonate}`);
  
  // Check if the impersonation was successful
  const currentSigner = await getSignerAddress();
  console.log(`Current deployer after impersonation: ${currentSigner}`);
  
  // Verify the signer by trying to send a small transaction
  try {
    const tx = await signer.sendTransaction({
      to: signer.address,
      value: ethers.utils.parseEther("0")
    });
    console.log(`Verification transaction sent: ${tx.hash}`);
  } catch (error) {
    console.error(`Error verifying impersonated signer: ${error.message}`);
    throw new Error("Impersonation failed - check that you're using a local Anvil node with fork");
  }
  
  return signer;
}

((async () => {
  // Initialize deployment with impersonation
  await impersonateDeployer();
  // await deployPool();
  // await deployCore();
  await deployVaults();
  await registerVaults();
  await deployGauge();
  // await deployGearbox();
  // await logVaults();
  // await verifyAllDeployedContracts();
})()).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
