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

// Main execution function
((async () => {
  try {
    // Initialize deployment with impersonation
    // uncomment this to deploy as the impersonated account, only supported on local deployment(anvil)
    // await impersonateDeployer();

    await deployInterestRateModel();
    
    // await deployCore();
    // await deployVaults();
    // await registerVaults(CONFIG_NETWORK);
    // await deployGauge(CONFIG_NETWORK.Core.PoolV3_LpETH, CONFIG_NETWORK, false);
    // await deployGearbox();
    // await logVaults();
    // await verifyAllDeployedContracts();
    // const pools = await deployPools(CONFIG_NETWORK, addressProviderV3);
    
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
