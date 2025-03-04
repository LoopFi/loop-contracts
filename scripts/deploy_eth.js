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
  getPoolAddress
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
  console.log('StakingLPEth deployed to:', stakingLpEth.address);
  console.log('LockingLpEth deployed to:', lockLpEth.address);

  const treasuryReplaceParams = {
    'deployer': signer,
    'stakingLpEth': stakingLpEth.address
  };

  const { payees, shares, admin } = replaceParams(CONFIG_NETWORK.Core.Treasury.constructorArguments, treasuryReplaceParams);
  const treasury = await deployContract('Treasury', 'Treasury', false, payees, shares, admin);
  console.log('Treasury deployed to:', treasury.address);
  
  await addressProviderV3.setAddress(toBytes32('TREASURY'), treasury.address, false);
  await pool.setTreasury(treasury.address);

  // Deploy Vault Registry
  const vaultRegistry = await deployContract('VaultRegistry');
  console.log('Vault Registry deployed to:', vaultRegistry.address);

  // Deploy actions with the vault registry
  const { flashlender, proxyRegistry } = await deployActionsAndFlashlender(pool, vaultRegistry);
  
  console.log('------------------------------------');
}

async function deployStakingAndLockingLP(pool) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                  DEPLOYING STAKING & LOCKING LP
//////////////////////////////////////////////////////////////*/
  `);

  const minShares = "10000"; // 0.01 * 10^6
  const stakingLpEth = await deployContract(
    'StakingLPEth', 
    'StakingLPEth', 
    false, 
    pool.address, 
    "StakingLPETH", 
    "slpETH",
    minShares
  );
  console.log('StakingLPEth deployed to:', stakingLpEth.address);

  const lockLpEth = await deployContract(
    'Locking', 
    'LockingLpETH',
    false, 
    pool.address
  );
  console.log('lockLpEth deployed to:', lockLpEth.address);

  await verifyOnTenderly('stakingLpEth', stakingLpEth.address);
  await verifyOnTenderly('LockingLPEth', lockLpEth.address);

  return { stakingLpEth, lockLpEth };
}

async function deployActionsAndFlashlender(pool, vaultRegistry) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING ACTIONS
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy Flashlender
  const flashlender = await deployContract('Flashlender', 'Flashlender', false, pool.address, CONFIG_NETWORK.Core.Flashlender.constructorArguments.protocolFee_);
  
  const UINT256_MAX = ethers.constants.MaxUint256;
  await pool.setCreditManagerDebtLimit(flashlender.address, UINT256_MAX);
  console.log('Set credit manager debt limit for flashlender to max');
  
  // Deploy PRBProxyRegistry
  const proxyRegistry = await deployContract('PRBProxyRegistry');
  console.log('PRBProxyRegistry deployed to ', proxyRegistry.address);
  
  const { swapAction, poolAction } = await deployActions(flashlender.address, vaultRegistry.address);

  return { flashlender, proxyRegistry, swapAction, poolAction };
}

async function deployActions(flashlenderAddress, vaultRegistryAddress) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING ACTIONS
//////////////////////////////////////////////////////////////*/
  `);

  console.log('flashlenderAddress', flashlenderAddress);
  console.log('vaultRegistryAddress', vaultRegistryAddress);

    // Deploy Actions
    const swapAction = await deployContract(
        'SwapAction', 'SwapAction', false, ...Object.values(CONFIG_NETWORK.Core.Actions.SwapAction.constructorArguments)
    );
    const poolAction = await deployContract(
        'PoolAction', 'PoolAction', false, ...Object.values(CONFIG_NETWORK.Core.Actions.PoolAction.constructorArguments)
    );
    
    // Deploy ERC165Plugin and Position Actions
    await deployContract('PositionAction20', 'PositionAction20', false, flashlenderAddress, swapAction.address, poolAction.address, vaultRegistryAddress, CONFIG_NETWORK.Core.WETH);
    await deployContract('PositionAction4626', 'PositionAction4626', false, flashlenderAddress, swapAction.address, poolAction.address, vaultRegistryAddress, CONFIG_NETWORK.Core.WETH);
    await deployContract('PositionActionPendle', 'PositionActionPendle', false, flashlenderAddress, swapAction.address, poolAction.address, vaultRegistryAddress, CONFIG_NETWORK.Core.WETH);
    await deployContract('PositionActionTranchess', 'PositionActionTranchess', false, flashlenderAddress, swapAction.address, poolAction.address, vaultRegistryAddress, CONFIG_NETWORK.Core.WETH);
    await deployContract('PositionActionPenpie', 'PositionActionPenpie', false, flashlenderAddress, swapAction.address, poolAction.address, vaultRegistryAddress, CONFIG_NETWORK.Core.WETH, CONFIG_NETWORK.Core.PenpieHelper);

    
    console.log('------------------------------------');

    return { swapAction, poolAction };
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

  if (config.oracle.type == "tETH") {
    return await deployVaultOracle_tETH(key, config);
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
    // await cdm["setParameter(address,bytes32,uint256)"](cdpVault.address, toBytes32("debtCeiling"), config.deploymentArguments.debtCeiling);
    
    console.log('------------------------------------');

    console.log('Initialized', vaultName, 'with a debt ceiling of', fromWad(config.deploymentArguments.debtCeiling), 'Credit');

    // deploy reward manager with vault reference
    const rewardManager = await deployContract(
      config.RewardManager.artifactName,
      `RewardManager_${key}`, // Include vault name in reward manager identifier
      false,
      cdpVault.address,
      tokenAddress,
      prbProxyRegistry.address,
      ...Object.values(config.RewardManager.constructorArguments)
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

async function redeployActions() {
    const { Flashlender: flashlender, VaultRegistry: vaultRegistry } = await loadDeployedContracts();
    console.log('flashlenderAddress', flashlender.address);
    console.log('vaultRegistryAddress', vaultRegistry.address);

    await deployActions(flashlender.address, vaultRegistry.address);
}

((async () => {

//   await deployCore();
  await redeployActions();
  await deployVaults();
  await registerVaults();
  // await deployGauge();
  // await deployGearbox();
  // await logVaults();
  // await verifyAllDeployedContracts();
})()).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
