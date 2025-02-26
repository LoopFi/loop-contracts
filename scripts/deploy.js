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
  loadDeployedVaults
} = require('./utils/deployUtils');
const CONFIG = require('./config.js');

const network = process.env.CONFIG_NETWORK || process.argv.find(arg => arg.startsWith('--network='))?.split('=')[1] || 'mainnet';

const CONFIG_NETWORK = (() => {
  try {
    return require(`./config_${network}.js`);
  } catch (e) {
    console.log(`Config file for network ${network} not found, using default config.js`);
    return require('./config.js');
  }
})();

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);
const toWad = ethers.utils.parseEther;
const fromWad = ethers.utils.formatEther;
const toBytes32 = ethers.utils.formatBytes32String;

function convertBigNumberToString(value) {
  if (ethers.BigNumber.isBigNumber(value)) return value.toString();
  if (value instanceof Array) return value.map((v) => convertBigNumberToString(v));
  if (value instanceof Object) return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, convertBigNumberToString(v)]));
  return value;
}

function replaceParams(obj, replacements) {
  if (Array.isArray(obj)) {
      return obj.map(v => replacements[v] !== undefined ? replacements[v] : v);
  } else if (typeof obj === 'object' && obj !== null) {
      return Object.fromEntries(
          Object.entries(obj).map(([k, v]) => [k, replaceParams(v, replacements)])
      );
  } else {
      return replacements[obj] !== undefined ? replacements[obj] : obj;
  }
}

async function verifyOnTenderly(name, address) {
  if (hre.network.name != 'tenderly') return;
  console.log('Verifying on Tenderly...');
  try {
    await hre.tenderly.verify({ name, address });
    console.log('Verified on Tenderly');
  } catch (error) {
    console.log('Failed to verify on Tenderly');
  }
}

async function storeEnvMetadata(metadata) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.environment == undefined) metadataFile.environment = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.environment = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

async function storeVaultMetadata(address, metadata) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.vaults == undefined) metadataFile.vaults = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.vaults[address] = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

async function getVaultMetadata(address) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  return metadataFile.vaults[address];
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

  const { AddressProviderV3: addressProviderV3 } = await deployGearboxCore();
  const pools = await deployPools(addressProviderV3);
  
  // Use the first pool as the main pool for remaining setup
  const pool = pools[0];

  console.log('PoolV3 deployed to:', pool.address);
  console.log('AddressProviderV3 deployed to:', addressProviderV3.address);

  const { stakingLpEth, lockLpEth } = await deployStakingAndLockingLP(pool);

  const treasuryReplaceParams = {
    'deployer': signer,
    'stakingLpEth': stakingLpEth.address
  };

  const { payees, shares, admin } = replaceParams(CONFIG.Core.Treasury.constructorArguments, treasuryReplaceParams);
  const treasury = await deployContract('Treasury', 'Treasury', false, payees, shares, admin);
  console.log('Treasury deployed to:', treasury.address);
  
  await addressProviderV3.setAddress(toBytes32('TREASURY'), treasury.address, false);
  await pool.setTreasury(treasury.address);

  // Deploy Vault Registry
  const vaultRegistry = await deployContract('VaultRegistry');
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

  const minShares = toWad("0.01").toString();
  const stakingLpEth = await deployContract(
    'StakingLPEth', 
    'StakingLPEth', 
    false, 
    pool.address, 
    "StakingLPEth", 
    "slpETH",
    minShares
  );
  console.log('StakingLPEth deployed to:', stakingLpEth.address);

  const lockLpEth = await deployContract(
    'Locking', 
    'LockingLpEth', 
    false, 
    pool.address
  );
  console.log('LockLPEth deployed to:', lockLpEth.address);

  await verifyOnTenderly('StakingLPEth', stakingLpEth.address);
  await storeContractDeployment(false, 'StakingLPEth', stakingLpEth.address, 'StakingLPEth');

  await verifyOnTenderly('LockingLPEth', lockLpEth.address);
  await storeContractDeployment(false, 'LockingLPEth', lockLpEth.address, 'StakingLPEth');

  return { stakingLpEth, lockLpEth };
}

async function deployActions(pool, vaultRegistry) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING ACTIONS
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy Flashlender
  const flashlender = await deployContract('Flashlender', 'Flashlender', false, pool.address, CONFIG.Core.Flashlender.constructorArguments.protocolFee_);
  
  const UINT256_MAX = ethers.constants.MaxUint256;
  await pool.setCreditManagerDebtLimit(flashlender.address, UINT256_MAX);
  console.log('Set credit manager debt limit for flashlender to max');
  
  // Deploy PRBProxyRegistry
  const proxyRegistry = await deployContract('PRBProxyRegistry');
  console.log('PRBProxyRegistry deployed to ', proxyRegistry.address);
  
  // Deploy Actions
  const swapAction = await deployContract(
   'SwapAction', 'SwapAction', false, ...Object.values(CONFIG.Core.Actions.SwapAction.constructorArguments)
  );
  const poolAction = await deployContract(
   'PoolAction', 'PoolAction', false, ...Object.values(CONFIG.Core.Actions.PoolAction.constructorArguments)
  );

  // Deploy ERC165Plugin and Position Actions
  await deployContract('ERC165Plugin');
  await deployContract('PositionAction20', 'PositionAction20', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  await deployContract('PositionAction4626', 'PositionAction4626', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  await deployContract('PositionActionPendle', 'PositionActionPendle', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  await deployContract('PositionActionTranchess', 'PositionActionTranchess', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  
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

  const liquidityPool = await attachContract('PoolV3', poolAddress);
  const latestBlock = await ethers.provider.getBlock('latest');
  const blockTimestamp = latestBlock.timestamp;
  const firstEpochTimestamp = blockTimestamp + 300; // Start 5 minutes from now
  
  const voter = await deployContract('LoopVoter', 'LoopVoter', false, addressProviderV3.address, firstEpochTimestamp);
  console.log(`Voter deployed to: ${voter.address}`);

  // Deploy GaugeV3 contract
  const gaugeV3 = await deployContract('GaugeV3', 'GaugeV3', false, liquidityPool.address, voter.address);
  console.log(`GaugeV3 deployed to: ${gaugeV3.address}`);
  
  // Assuming quotaKeeper and other necessary contracts are already deployed and their addresses are known
  const poolQuotaKeeperV3 = await deployContract('PoolQuotaKeeperV3', 'PoolQuotaKeeperV3', false, liquidityPool.address);
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
  await storeContractDeployment(false, 'ACL', ACL.address, 'ACL');
  
  await verifyOnTenderly('AddressProviderV3', AddressProviderV3.address);
  await storeContractDeployment(false, 'AddressProviderV3', AddressProviderV3.address, 'AddressProviderV3');
  
  await verifyOnTenderly('ContractsRegister', ContractsRegister.address);
  await storeContractDeployment(false, 'ContractsRegister', ContractsRegister.address, 'ContractsRegister');

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
    
    await verifyOnTenderly('LinearInterestRateModelV3', LinearInterestRateModelV3.address);
    await storeContractDeployment(false, `LinearInterestRateModelV3_${poolKey}`, LinearInterestRateModelV3.address, 'LinearInterestRateModelV3');
    
    await verifyOnTenderly('PoolV3', PoolV3.address);
    await storeContractDeployment(false, `PoolV3_${poolKey}`, PoolV3.address, 'PoolV3');

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
  await storeContractDeployment(false, 'LinearInterestRateModelV3', LinearInterestRateModelV3.address, 'LinearInterestRateModelV3');
  
  await verifyOnTenderly('ACL', ACL.address);
  await storeContractDeployment(false, 'ACL', ACL.address, 'ACL');
  
  await verifyOnTenderly('AddressProviderV3', AddressProviderV3.address);
  await storeContractDeployment(false, 'AddressProviderV3', AddressProviderV3.address, 'AddressProviderV3');
  
  await verifyOnTenderly('ContractsRegister', ContractsRegister.address);
  await storeContractDeployment(false, 'ContractsRegister', ContractsRegister.address, 'ContractsRegister');
  
  await verifyOnTenderly('PoolV3', PoolV3.address);
  await storeContractDeployment(false, 'PoolV3', PoolV3.address, 'PoolV3');

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
    if (poolAddress == undefined || poolAddress == null) {
      console.log('No pool address defined for', key);
      return;
    }
    console.log('poolAddress', poolAddress);
    
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
      [...Object.values(config.deploymentArguments.configs).map((v) => v === "deployer" ? signer : v)]
    );

    console.log('CDPVault deployed for', vaultName, 'at', cdpVault.address);

    console.log('Set debtCeiling to', fromWad(config.deploymentArguments.debtCeiling), 'for', vaultName);
    const pool = await attachContract('PoolV3', poolAddress);
    await pool.setCreditManagerDebtLimit(cdpVault.address, config.deploymentArguments.debtCeiling);
    // await cdm["setParameter(address,bytes32,uint256)"](cdpVault.address, toBytes32("debtCeiling"), config.deploymentArguments.debtCeiling);
    
    console.log('------------------------------------');

    console.log('Initialized', vaultName, 'with a debt ceiling of', fromWad(config.deploymentArguments.debtCeiling), 'Credit');

    // deploy reward manager
    
    const rewardManager = await deployContract(
      "src/pendle-rewards/RewardManager.sol:RewardManager",
      "RewardManager",
      false, 
      cdpVault.address,
      tokenAddress,
      prbProxyRegistry.address
    );

    console.log('Deployed RewardManager for', vaultName, 'at', rewardManager.address);

    await cdpVault["setParameter(bytes32,address)"](toBytes32("rewardManager"), rewardManager.address);
    console.log('Set reward manager for', vaultName, 'to', rewardManager.address);

    // if (config.oracle)
    // await oracle.updateSpot(tokenAddress, config.oracle.defaultPrice);
    // console.log('Updated default price for', key, 'to', fromWad(config.oracle.defaultPrice), 'USD');

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
  const { VaultRegistry: vaultRegistry } = await loadDeployedContracts()
  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    console.log(`${name}: ${vault.address}`);
    await vaultRegistry.addVault(vault.address);

    console.log('Added', name, 'to vault registry');
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

async function getPoolAddress(poolName) {
  poolName = "PoolV3_" + poolName;
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};

  
  // Look for pool directly in core section
  if (deployment.core && deployment.core[poolName]) {
    return deployment.core[poolName].address;
  }
  
  throw new Error(`Pool ${poolName} not found in deployment file`);
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

  // Deploy Combined4626AggregatorV3Oracle
  const combined4626Oracle = await deployContract(
    'Combined4626AggregatorV3Oracle',
    'Combined4626AggregatorV3Oracle',
    false,
    pythAggregator.address,
    3600, // heartbeat
    oracleConfig.wstUSRVault
  );
  console.log(`Combined4626AggregatorV3Oracle deployed for ${key} at ${combined4626Oracle.address}`);

  // Deploy CombinedAggregatorV3Oracle
  const combinedOracle = await deployContract(
    'CombinedAggregatorV3Oracle',
    'CombinedAggregatorV3Oracle',
    false,
    combined4626Oracle.address,
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

((async () => {
  await deployCore();
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
