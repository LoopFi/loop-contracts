const fs = require('fs');
const path = require('path');
const { ethers } = require('hardhat');
const hre = require('hardhat');

async function getSignerAddress() {
  return (await ethers.getSigners())[0].address;
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
  loadDeployedRewardManagers
}; 