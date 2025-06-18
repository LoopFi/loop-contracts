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
  deployCustomPositionActions,
  deployVaultOracle,
  registerVaults,
  deployPools,
  deployPoolWithType,
} = require('./utils/deployUtils');
const { 
  getNetworkName, 
  loadConfig 
} = require('./utils/configUtils');

// Hardcode the config type for this specific deployment script
const CONFIG_TYPE = 'bsc';

// Load the network-specific and/or token-specific config
const CONFIG_NETWORK = loadConfig(CONFIG_TYPE);

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);
const toWad = ethers.utils.parseEther;
const fromWad = ethers.utils.formatEther;
const toBytes32 = ethers.utils.formatBytes32String;

async function deployCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING CORE
//////////////////////////////////////////////////////////////*/
  `);

  const poolType = 'btc';
  
  // Get addressProviderV3 from config
  const addressProviderV3 = await attachContract('AddressProviderV3', CONFIG_NETWORK.Core.AddressProviderV3);
  console.log('AddressProviderV3:', addressProviderV3.address);
  
  // Deploy the pool
  const pool = await deployPoolWithType(
    CONFIG_NETWORK, 
    addressProviderV3, 
    poolType, 
    'LiquidityPoolBTCB', 
    CONFIG_NETWORK.Pools.LiquidityPoolBTCB
  );
  console.log('Pool deployed at', pool.address);
  
  // Store the pool address in the config so deployPoolCore can use it
  const poolKey = `PoolV3_LiquidityPoolBTCB_${poolType}`;
  CONFIG_NETWORK.Core[poolKey] = pool.address;
  console.log(`Stored pool address in CONFIG_NETWORK.Core.${poolKey}`);
  
  const positionActions = [
    'PositionAction20',
    'PositionAction4626',
  ];

  // Deploy core components for the pool
  const deployedCore = await deployPoolCore(CONFIG_NETWORK, poolType, poolKey, positionActions);
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
  const {
    PRBProxyRegistry: prbProxyRegistry,
  } = await loadDeployedContracts();
  
  for (const [key, config] of Object.entries(CONFIG_NETWORK.Vaults)) {
    const vaultName = config.name || `CDPVault_${key}`;
    console.log('deploying vault ', vaultName);

    // Deploy oracle using our updated deployCustomVaultOracle function
    const oracleAddress = await deployCustomVaultOracle(key, config);
    
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
    // await pool.setCreditManagerDebtLimit(cdpVault.address, config.deploymentArguments.debtCeiling);
    
    console.log('------------------------------------');

    console.log('Initialized', vaultName, 'with a debt ceiling of', fromWad(config.deploymentArguments.debtCeiling), 'Credit');

    const rewardManager = await deployContract(
      config.RewardManager.artifactName,
      `RewardManager_${vaultName}`,
      false,
      cdpVault.address,
      tokenAddress,
      prbProxyRegistry.address,
      ...Object.values(config.RewardManager.constructorArguments).map(v => v === "deployer" ? signer : v)
    );

    // Store reward manager with vault reference
    await storeContractDeployment(
      false,
      `RewardManager_${vaultName}`,
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
        vaultAddress: cdpVault.address,
        addedToRegistry: false,
        addedToGauge: false
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

async function deployGauge(poolAddress) {
  console.log(`
    /*//////////////////////////////////////////////////////////////
                            DEPLOYING GAUGE
    //////////////////////////////////////////////////////////////*/
  `);

  if (!poolAddress) {
    console.log('No pool address defined for gauge');
    return;
  }

  const gaugeV3 = await attachContract('GaugeV3', CONFIG_NETWORK.Core.GaugeV3);
  const poolQuotaKeeperV3 = await attachContract('PoolQuotaKeeperV3', CONFIG_NETWORK.Core.PoolQuotaKeeperV3);
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));

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

    // Check if vault is already added to gauge
    if (deployment.vaults[name] && !deployment.vaults[name].addedToGauge) {
      const tokenAddress = await vault.token();
      await poolQuotaKeeperV3.setCreditManager(tokenAddress, vault.address);
      console.log('Set Credit Manager in QuotaKeeper for token:', tokenAddress);
      
      const minRate = vaultMetadata.quotas.minRate;
      const maxRate = vaultMetadata.quotas.maxRate;
      
      console.log('Setting quota rates for token:', tokenAddress, 'minRate:', minRate, 'maxRate:', maxRate);
      await gaugeV3.addQuotaToken(tokenAddress, minRate, maxRate);
      console.log('Added quota token to GaugeV3 for token:', tokenAddress);

      // Update the gauge status
      deployment.vaults[name].addedToGauge = true;
      fs.writeFileSync(deploymentFilePath, JSON.stringify(deployment, null, 2));
    } else {
      console.log(`${name} already added to gauge or not ready for gauge, skipping`);
    }
  }

  // Unfreeze the epoch in Gauge
  await gaugeV3.setFrozenEpoch(false);
  console.log('Set frozen epoch to false in GaugeV3');
  
  console.log('Gauge and related configurations have been set.');
}

async function deployInterestRateModel() {
  //default values
  const U_1 = 7000; // U_1
  const U_2 = 9000; // U_2
  const R_base = 0; // R_base
  const R_slope1 = 1020; // R_slope1
  const R_slope2 = 1275; // R_slope2
  const R_slope3 = 3400; // R_slope3
  const version = 6;

  //decrease factor for slopes
  const decreaseFactor = 0.6; // 40% decrease

  console.log('Deploying LinearInterestRateModelV3_', version);
  console.log('R_slope1:', R_slope1 * decreaseFactor);
  console.log('R_slope2:', R_slope2 * decreaseFactor);
  console.log('R_slope3:', R_slope3 * decreaseFactor);

  const LinearInterestRateModelV3 = await deployContract(
    'LinearInterestRateModelV3',
    `LinearInterestRateModelV3_${version}`,
    false,
    U_1,
    U_2,
    R_base,
    Math.round(R_slope1 * decreaseFactor),
    Math.round(R_slope2 * decreaseFactor),
    Math.round(R_slope3 * decreaseFactor), 
    false
  );

  return LinearInterestRateModelV3;
}


async function redeployActions() {
  const poolType = 'bnb';
  const config = CONFIG_NETWORK;

  // const swapAction = await deployContract(
  //   'SwapAction',
  //   `SwapAction_${poolType}`,
  //   false,
  //   ...Object.values(config.Core.Actions.SwapAction.constructorArguments)
  // );

  // const poolAction = await deployContract(
  //   'PoolAction',
  //   `PoolAction_${poolType}`,
  //   false,
  //   ...Object.values(config.Core.Actions.PoolAction.constructorArguments)
  // );

  const swapAction = await attachContract('SwapAction', CONFIG_NETWORK.Core.SwapAction);
  const poolAction = await attachContract('PoolAction', CONFIG_NETWORK.Core.PoolAction);
  const flashlender = await attachContract('Flashlender', CONFIG_NETWORK.Core.Flashlender);
  const vaultRegistry = await attachContract('VaultRegistry', CONFIG_NETWORK.Core.VaultRegistry);

  const positionActions = [
    'PositionActionPendle',
  ];

  await deployCustomPositionActions(flashlender, swapAction, poolAction, vaultRegistry, poolType, config, positionActions);
}

async function deployCustomVaultOracle(key, config) {
  if (!config.oracle) {
    console.log('No oracle defined for', key);
    return null;
  }

  const oracleType = config.oracle.type;
  
  if (oracleType === "StaticOracle") {
    return await deployStaticOracle(key, config);
  }
  
  console.log('Deploying default oracle for', key);
  const oracleConfig = config.oracle.deploymentArguments;
  const deployedOracle = await deployContract(
    oracleType,
    oracleType+'_'+key,
    false,
    ...Object.values(oracleConfig)
  );
  return deployedOracle.address;
}

/**
 * Deploys a StaticOracle contract as a proxy
 * @param {string} key - Identifier for the deployment
 * @param {Object} config - Configuration for the deployment
 * @returns {string} The address of the deployed StaticOracle proxy
 */
async function deployStaticOracle(key, config) {
  console.log('Deploying StaticOracle for', key);
  
  // Step 1: Deploy the StaticOracle implementation
  const staticOracleImpl = await deployContract(
    'StaticOracle',
    `StaticOracle_Impl_${key}`,
    false
  );
  console.log(`StaticOracle implementation deployed for ${key} at ${staticOracleImpl.address}`);

  // Step 2: Deploy the proxy
  const signer = await getSignerAddress();
  
  // Get the contract factory for the proxy
  const ERC1967Proxy = await ethers.getContractFactory('ERC1967Proxy');
  
  // Create initialization data for the proxy
  const initData = staticOracleImpl.interface.encodeFunctionData('initialize', [signer, signer]);
  
  // Deploy the proxy
  const proxy = await ERC1967Proxy.deploy(
    staticOracleImpl.address,
    initData
  );
  await proxy.deployed();
  
  const staticOracle = await ethers.getContractAt('StaticOracle', proxy.address);
  console.log(`StaticOracle proxy deployed for ${key} at ${staticOracle.address}`);

  // Store deployment records
  await storeContractDeployment(
    false,
    `StaticOracle_Impl_${key}`,
    staticOracleImpl.address,
    'StaticOracle',
    []
  );
  
  await storeContractDeployment(
    false,
    `StaticOracle_${key}`,
    staticOracle.address,
    'ERC1967Proxy',
    [staticOracleImpl.address, initData]
  );

  return staticOracle.address;
}

((async () => {
  // await deployInterestRateModel();
  // await redeployActions();
  await deployCore();
  await deployVaults();
  await registerVaults(CONFIG_NETWORK);
  // await deployGauge(CONFIG_NETWORK.Core.PoolV3_LpBNB);
  // await deployGearbox();
  // await logVaults();
  // await verifyAllDeployedContracts();

  // const pools = await deployPools(CONFIG_NETWORK, addressProviderV3);
})()).catch((error) => {
  console.error(error);
  process.exit(1);
});
