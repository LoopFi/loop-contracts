const fs = require('fs');
const path = require('path');
const { ethers } = require('hardhat');
const hre = require('hardhat');

async function getSignerAddress() {
  // Check if we have an override from impersonation
  if (global.getSignerAddressOverride) {
    return global.getSignerAddressOverride;
  }
  
  // Otherwise use the default approach
  const [signer] = await ethers.getSigners();
  return await signer.getAddress();
}

async function getDeploymentFilePath() {
  return path.join(__dirname, '..', `deployment-${hre.network.name}.json`);
}

async function storeContractDeployment(isVault, name, address, artifactName, constructorArgs = [], rewardManagerData = null) {
  const deploymentFilePath = await getDeploymentFilePath();
  
  // Initialize with all required sections when file doesn't exist or is empty
  const deployment = fs.existsSync(deploymentFilePath) ? 
    JSON.parse(fs.readFileSync(deploymentFilePath)) || { core: {}, vaults: {}, rewardManagers: {} } : 
    { core: {}, vaults: {}, rewardManagers: {} };
  
  // Ensure all sections exist even if file exists but is missing sections
  deployment.core = deployment.core || {};
  deployment.vaults = deployment.vaults || {};
  deployment.rewardManagers = deployment.rewardManagers || {};
  
  // Properly serialize constructor arguments
  const serializedArgs = [];
  
  for (let i = 0; i < constructorArgs.length; i++) {
    const arg = constructorArgs[i];
    
    if (Array.isArray(arg)) {
      serializedArgs.push(arg.map(item => 
        item === null || item === undefined ? '' : item.toString()
      ));
    } else if (arg === null || arg === undefined) {
      serializedArgs.push('');
    } else if (typeof arg === 'object') {
      if (ethers.BigNumber.isBigNumber(arg)) {
        serializedArgs.push(arg.toString());
      } else {
        try {
          serializedArgs.push(arg.toString());
        } catch (e) {
          serializedArgs.push(JSON.stringify(arg));
        }
      }
    } else {
      serializedArgs.push(arg.toString());
    }
  }

  const contractData = {
    address,
    artifactName,
    constructorArgs: serializedArgs,
    addedToRegistry: false
  };

  if (isVault) {
    deployment.vaults[name] = contractData;
  } else if (rewardManagerData) {
    // Store reward manager with reference to its vault
    deployment.rewardManagers[address] = {
      ...contractData,
      vaultName: rewardManagerData.vaultName,
      vaultAddress: rewardManagerData.vaultAddress
    };
  } else {
    deployment.core[name] = contractData;
  }
  
  fs.writeFileSync(deploymentFilePath, JSON.stringify(deployment, null, 2));
  
  // Verify the file was written correctly
  const verifyDeployment = JSON.parse(fs.readFileSync(deploymentFilePath));
}

/**
 * Deploys a contract
 * @param {string} name - The name of the contract artifact
 * @param {string} artifactName - The name to use for the contract in deployment records
 * @param {boolean} isVault - Whether this is a vault contract
 * @param {...any} args - The constructor arguments
 * @returns {Object} The deployed contract
 */
async function deployContract(name, artifactName, isVault, ...args) {
  console.log(`Deploying ${artifactName || name}...`);
  
  // // Check if the contract is already deployed
  // if (await isContractDeployed(artifactName || name)) {
  //   console.log(`${artifactName || name} already deployed, skipping`);
  //   return await getDeployedContract(artifactName || name);
  // }

  const Contract = await ethers.getContractFactory(name);
  
  console.log('Deploying contract', name, 'with args', args.map((v) => v.toString()).join(', '));
  const contract = await Contract.deploy(...args);
  await contract.deployed();

  console.log(`${artifactName || name} deployed to: ${contract.address}`);
  await verifyOnTenderly(name, contract.address);

  await storeContractDeployment(
    isVault,
    artifactName || name,
    contract.address,
    name,
    args
  );

  return contract;
}

async function isContractDeployed(name) {
  const deploymentFilePath = await getDeploymentFilePath();
  if (!fs.existsSync(deploymentFilePath)) return false;
  
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  const normalizedName = name.toLowerCase();
  
  // Check in both core and vaults, with both original and normalized names
  return (deployment.core && (deployment.core[name] || deployment.core[normalizedName])) || 
         (deployment.vaults && (deployment.vaults[name] || deployment.vaults[normalizedName]));
}

async function getDeployedContract(name) {
  const deploymentFilePath = await getDeploymentFilePath();
  if (!fs.existsSync(deploymentFilePath)) return null;
  
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  const normalizedName = name.toLowerCase();
  
  // Look for contract data with both original and normalized names
  const contractData = (deployment.core && (deployment.core[name] || deployment.core[normalizedName])) || 
                      (deployment.vaults && (deployment.vaults[name] || deployment.vaults[normalizedName]));

  if (!contractData) return null;
  
  return {
    contract: await ethers.getContractFactory(contractData.artifactName).then(f => f.attach(contractData.address)),
    address: contractData.address
  };
}

async function attachContract(name, address) {
  return await ethers.getContractAt(name, address);
}

async function loadDeployedContracts() {
  console.log('Loading deployed contracts...');
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  const contracts = {};

  for (let [name, { address, artifactName }] of Object.entries({ 
    ...(deployment.core || {}), 
    ...(deployment.vaults || {}) 
  })) {
    if (artifactName.includes('IWeightedPool')) continue;
    
    const normalizedName = name.toLowerCase();
    const contract = (await ethers.getContractFactory(artifactName)).attach(address);
    
    // Store contract under both original and normalized names
    contracts[name] = contract;
    contracts[normalizedName] = contract;
  }
  return contracts;
}

async function loadDeployedVaults() {
  console.log('Loading deployed vaults...');
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  const contracts = {};
  
  for (let [name, { address, artifactName }] of Object.entries(deployment.vaults || {})) {
    // Store only the original name to prevent duplicates in logging
    contracts[name] = (await ethers.getContractFactory(artifactName)).attach(address);
  }
  return contracts;
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

/**
 * Converts BigNumber values to strings in an object or array
 * @param {*} value - The value to convert (can be a BigNumber, array, or object)
 * @returns {*} The converted value
 */
function convertBigNumberToString(value) {
  if (ethers.BigNumber.isBigNumber(value)) return value.toString();
  if (value instanceof Array) return value.map((v) => convertBigNumberToString(v));
  if (value instanceof Object) return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, convertBigNumberToString(v)]));
  return value;
}

/**
 * Replaces parameters in an object or array with values from a replacements object
 * @param {*} obj - The object or array to process
 * @param {Object} replacements - Object containing replacement values
 * @returns {*} The processed object with replacements applied
 */
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

/**
 * Stores environment metadata in a JSON file
 * @param {Object} metadata - The metadata to store
 */
async function storeEnvMetadata(metadata) {
  const metadataFilePath = path.join(__dirname, '..', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.environment == undefined) metadataFile.environment = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.environment = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

/**
 * Stores vault metadata in a JSON file
 * @param {string} address - The vault address
 * @param {Object} metadata - The metadata to store
 */
async function storeVaultMetadata(address, metadata) {
  const metadataFilePath = path.join(__dirname, '..', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.vaults == undefined) metadataFile.vaults = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.vaults[address] = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

/**
 * Gets vault metadata from a JSON file
 * @param {string} address - The vault address
 * @returns {Object} The vault metadata
 */
async function getVaultMetadata(address) {
  const metadataFilePath = path.join(__dirname, '..', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  return metadataFile.vaults?.[address];
}

/**
 * Gets the pool address from a pool key or returns the address if it's already an address
 * @param {string} poolName - The pool key or address
 * @returns {string|null} The pool address or null if not found
 */
async function getPoolAddress(poolName) {
  // Check if poolName is already an Ethereum address
  if (ethers.utils.isAddress(poolName)) {
    console.log(`Pool name is already an address: ${poolName}`);
    return poolName;
  }

  // Format the pool name correctly for lookup
  const formattedPoolName = `PoolV3_${poolName}`;
  console.log(`Looking for pool with name: ${formattedPoolName}`);
  
  const deploymentFilePath = await getDeploymentFilePath();
  if (!fs.existsSync(deploymentFilePath)) {
    console.log(`Deployment file not found at ${deploymentFilePath}`);
    return null;
  }
  
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  
  // Check if the pool exists in the core section
  if (deployment.core && deployment.core[formattedPoolName]) {
    console.log(`Found pool ${formattedPoolName} at ${deployment.core[formattedPoolName].address}`);
    return deployment.core[formattedPoolName].address;
  }
  
  console.log(`Pool ${formattedPoolName} not found in deployment file`);
  return null;
}

async function loadDeployedRewardManagers() {
  console.log('Loading deployed reward managers...');
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  const rewardManagers = {};
  
  for (let [address, data] of Object.entries(deployment.rewardManagers || {})) {
    const contract = await ethers.getContractFactory(data.artifactName).then(f => f.attach(address));
    rewardManagers[data.vaultName] = {
      contract,
      address,
      vaultAddress: data.vaultAddress
    };
    console.log(`Loaded reward manager for ${data.vaultName} at ${address}`);
  }
  return rewardManagers;
}

// Add new deployment utility functions

/**
 * Deploys core contracts including staking, locking LP, treasury, and actions
 * @param {Object} config - The network configuration object
 * @param {string} poolType - The pool type ('eth' or 'usdc')
 */
async function deployPoolCore(config, poolType) {
  const signer = await getSignerAddress();
  
  if (hre.network.name == 'tenderly') {
    await ethers.provider.send('tenderly_setBalance', [[signer], ethers.utils.hexValue(toWad('100').toHexString())]);
  }

  const addressProviderV3 = await attachContract('AddressProviderV3', config.Core.AddressProviderV3);
  const pool = await attachContract('PoolV3', config.Core.PoolV3_LpUSD);

  const { stakingLp, lockLp } = await deployStakingAndLockingLP(pool, poolType);
  console.log('staking lp property name', `stakingLp${poolType.toUpperCase()}`);
  
  const treasuryReplaceParams = {
    'deployer': signer,
    [`stakingLp${poolType.toUpperCase()}`]: stakingLp.address
  };

  const { payees, shares, admin } = replaceParams(config.Core.Treasury.constructorArguments, treasuryReplaceParams);
  const treasury = await deployContract('Treasury', 'Treasury', false, payees, shares, admin);
  
  await pool.setTreasury(treasury.address);

  const vaultRegistry = await attachContract('VaultRegistry', config.Core.VaultRegistry);
  const { flashlender, proxyRegistry } = await deployActions(pool, vaultRegistry, poolType, config);

  return {
    stakingLp,
    lockLp,
    treasury,
    vaultRegistry,
    flashlender,
    proxyRegistry
  };
}

/**
 * Deploys staking and locking LP contracts
 * @param {Contract} pool - The pool contract
 * @param {string} poolType - The pool type ('eth' or 'usdc')
 */
async function deployStakingAndLockingLP(pool, poolType) {
  const minShares = "10000"; // 0.01 * 10^6
  const upperPoolType = poolType.toUpperCase();
  
  const stakingLp = await deployContract(
    'StakingLPEth',
    `StakingLP${upperPoolType}`,
    false,
    pool.address,
    `StakingLP${upperPoolType}`,
    `slp${upperPoolType}`,
    minShares
  );

  const lockLp = await deployContract(
    'Locking',
    `LockingLp${upperPoolType}`,
    false,
    pool.address
  );

  return { stakingLp, lockLp };
}

/**
 * Deploys actions contracts
 * @param {Contract} pool - The pool contract
 * @param {Contract} vaultRegistry - The vault registry contract
 * @param {string} poolType - The pool type ('eth' or 'usdc')
 */
async function deployActions(pool, vaultRegistry, poolType, config) {
  const flashlender = await deployContract(
    'Flashlender',
    `Flashlender_${poolType}`,
    false,
    pool.address,
    config.Core.Flashlender.constructorArguments.protocolFee_
  );

  const UINT256_MAX = ethers.constants.MaxUint256;
  await pool.setCreditManagerDebtLimit(flashlender.address, UINT256_MAX);

  const proxyRegistry = await deployContract('PRBProxyRegistry');

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

  // Deploy position actions
  await deployPositionActions(flashlender, swapAction, poolAction, vaultRegistry, poolType, config);

  return { flashlender, proxyRegistry, swapAction, poolAction };
}

/**
 * Deploys position action contracts
 * @param {Contract} flashlender - The flashlender contract
 * @param {Contract} swapAction - The swap action contract
 * @param {Contract} poolAction - The pool action contract
 * @param {Contract} vaultRegistry - The vault registry contract
 * @param {string} poolType - The pool type ('eth' or 'usdc')
 */
async function deployPositionActions(flashlender, swapAction, poolAction, vaultRegistry, poolType, config) {
  const positionActions = [
    'PositionAction20',
    'PositionAction4626',
    'PositionActionPendle',
    'PositionActionTranchess',
    'PositionActionPenpie'
  ];

  for (const action of positionActions) {
    const args = [
      flashlender.address,
      swapAction.address,
      poolAction.address,
      vaultRegistry.address,
      config.Core.WETH
    ];

    if (action === 'PositionActionPenpie') {
      args.push(config.Core.PenpieHelper);
    }

    await deployContract(
      action,
      `${action}_${poolType}`,
      false,
      ...args
    );
  }
}

/**
 * Base oracle deployment function
 * @param {string} key - The oracle key
 * @param {Object} config - The oracle configuration
 * @param {Object} oracleDeployers - Map of oracle type to deployer function
 */
async function deployVaultOracle(key, config, oracleDeployers) {
  if (!config.oracle) {
    console.log('No oracle defined for', key);
    return null;
  }

  const oracleType = config.oracle.type;
  const deployer = oracleDeployers[oracleType];
  
  if (!deployer) {
    console.log('Deploying default oracle for', key);
    const oracleConfig = config.oracle.deploymentArguments;
    const deployedOracle = await deployContract(
      oracleType,
      oracleType,
      false,
      ...Object.values(oracleConfig)
    );
    return deployedOracle.address;
  }

  return await deployer(key, config);
}

/**
 * Registers vaults in the vault registry
 */
async function registerVaults(config) {
  const vaultRegistry = await attachContract('VaultRegistry', config.Core.VaultRegistry);
  
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));

  if (!vaultRegistry) {
    console.log('Vault registry not found');
    return;
  }
  
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

/**
 * Deploys pools with their interest rate models
 * @param {Object} config - The network configuration object
 * @param {Contract} addressProviderV3 - The address provider contract
 */
async function deployPools(config, addressProviderV3) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING POOLS
//////////////////////////////////////////////////////////////*/
  `);

  const pools = [];
  
  for (const [poolKey, poolConfig] of Object.entries(config.Pools)) {
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
      poolConfig.initialDebtCeiling || config.Core.Gearbox.initialGlobalDebtCeiling,
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

/**
 * Impersonates an account using anvil's impersonation feature and sets it as the default signer
 * @param {string} address - The address to impersonate
 * @returns {Promise<ethers.Signer>} - An ethers Signer connected to the impersonated account
 */
async function impersonateAccount(address) {
  console.log(`Impersonating account: ${address}`);
  
  // Send the anvil_impersonateAccount JSON-RPC request
  await ethers.provider.send("anvil_impersonateAccount", [address]);
  
  // Get a signer for the impersonated account
  const impersonatedSigner = await ethers.getSigner(address);
  
  // Check the current signer balance and fund if necessary
  const balance = await ethers.provider.getBalance(address);
  console.log(`Impersonated account balance: ${ethers.utils.formatEther(balance)} ETH`);
  
  // Store the original signer functions for later restoration
  const originalSigners = [...await ethers.getSigners()];
  
  // Replace the ethers.getSigners function to always return our impersonated signer first
  const originalGetSigners = ethers.getSigners;
  ethers.getSigners = async () => {
    return [impersonatedSigner, ...originalSigners.slice(1)];
  };
  
  // Replace the getSignerAddress function in deployUtils
  const originalGetSignerAddress = getSignerAddress;
  global.getSignerAddressOverride = address;
  
  // Return both the signer and utility functions for restoration later
  return {
    signer: impersonatedSigner,
    restore: async () => {
      ethers.getSigners = originalGetSigners;
      global.getSignerAddressOverride = undefined;
      await stopImpersonatingAccount(address);
    }
  };
}

/**
 * Stops impersonating a previously impersonated account
 * @param {string} address - The address to stop impersonating
 */
async function stopImpersonatingAccount(address) {
  console.log(`Stopping impersonation of account: ${address}`);
  await ethers.provider.send("anvil_stopImpersonatingAccount", [address]);
}

/**
 * Optional: Fund an account with ETH if needed
 * @param {string} address - The address to fund
 * @param {BigNumber} amount - The amount to fund
 */
async function fundAccount(address, amount) {
  console.log(`Funding account ${address} with ${ethers.utils.formatEther(amount)} ETH`);
  
  // Get a signer with some ETH (typically the default account in Anvil)
  const [signer] = await ethers.getSigners();
  
  // Send ETH to the target address
  await signer.sendTransaction({
    to: address,
    value: amount
  });
  
  console.log(`Funded account: ${address}`);
}

module.exports = {
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
  loadDeployedRewardManagers,
  deployPoolCore,
  deployStakingAndLockingLP,
  deployActions,
  deployPositionActions,
  deployVaultOracle,
  registerVaults,
  deployPools,
  // New functions for account impersonation
  impersonateAccount,
  stopImpersonatingAccount,
  fundAccount,
}; 