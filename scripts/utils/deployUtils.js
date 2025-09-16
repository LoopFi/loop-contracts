const fs = require('fs');
const path = require('path');
const { ethers } = require('hardhat');
const hre = require('hardhat');

// Helper function to get gas price from Bitlayer RPC
async function getBitlayerGasPrice() {
  try {
    const rpcUrls = [
      'https://rpc.bitlayer.org',
      'https://rpc.bitlayer-rpc.com', 
      'https://rpc.ankr.com/bitlayer'
    ];
    
    for (const rpcUrl of rpcUrls) {
      try {
        // Use ethers provider to make RPC call
        const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
        const gasPrice = await provider.getGasPrice();
        const gasPriceWei = gasPrice.toNumber();
        console.log(`📡 Got gas price from ${rpcUrl}: ${gasPriceWei} wei`);
        return gasPriceWei;
      } catch (error) {
        console.log(`⚠️  Failed to get gas price from ${rpcUrl}:`, error.message);
        continue;
      }
    }
    
    // Fallback to 7 wei if all RPCs fail
    console.log('⚠️  All RPC calls failed, using fallback gas price: 7 wei');
    return 7;
  } catch (error) {
    console.log('⚠️  Error getting Bitlayer gas price, using fallback: 7 wei');
    return 7;
  }
}

// Helper function to get gas options for the current network
async function getGasOptions() {
  // Only use Bitlayer gas pricing for actual Bitlayer network
  if (hre.network.name === 'bitlayer') {
    const gasPrice = await getBitlayerGasPrice();
    return { gasPrice };
  }
  
  // For all other networks (including local forks), use ethers provider gas price with buffer
  try {
    const gasPrice = await ethers.provider.getGasPrice();
    // Add a small buffer to ensure transaction goes through
    const bufferedGasPrice = gasPrice.mul(110).div(100); // 10% buffer
    console.log(`📡 ${hre.network.name} gas price: ${gasPrice.toString()} wei, buffered: ${bufferedGasPrice.toString()} wei`);
    return { gasPrice: bufferedGasPrice };
  } catch (error) {
    console.log(`⚠️  Error getting ${hre.network.name} gas price, using fallback: 1 gwei`);
    return { gasPrice: ethers.utils.parseUnits('1', 'gwei') };
  }
}

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
  
  try {
    const gasOptions = await getGasOptions();
    const contract = await Contract.deploy(...args, gasOptions);
    
    // The contract address is available immediately after deployment
    console.log(`Transaction hash: ${contract.deployTransaction.hash}`);
    console.log(`${artifactName || name} deployed to: ${contract.address}`);
    
    // Try to wait for confirmation, but don't fail if transaction response parsing fails
    try {
      const receipt = await contract.deployTransaction.wait();
      console.log(`Contract confirmed in block ${receipt.blockNumber}`);
      
      // Log transaction cost
      const gasUsed = receipt.gasUsed;
      const gasPrice = receipt.effectiveGasPrice || contract.deployTransaction.gasPrice;
      const txCost = gasUsed.mul(gasPrice);
      const txCostBTC = ethers.utils.formatEther(txCost);
      
      console.log(`💸 Gas used: ${gasUsed.toString()} | Cost: ${txCostBTC} BTC`);
      
      // Check remaining balance
      const signer = await ethers.getSigner();
      const remainingBalance = await signer.getBalance();
      const remainingBTC = ethers.utils.formatEther(remainingBalance);
      console.log(`💰 Remaining balance: ${remainingBTC} BTC`);
      
    } catch (waitError) {
      if (waitError.message.includes('invalid address')) {
        console.log('Warning: Transaction response parsing failed, but contract was deployed successfully');
        console.log('This is likely due to ethers.js v5 transaction response formatting issues');
        // We can still proceed since we have the contract address
      } else {
        throw waitError; // Re-throw if it's a different error
      }
    }

    await verifyOnTenderly(name, contract.address);

    await storeContractDeployment(
      isVault,
      artifactName || name,
      contract.address,
      name,
      args
    );

    return contract;
  } catch (error) {
    console.error(`Error deploying ${artifactName || name}:`, error.message);
    
    // If deployment itself failed due to transaction response parsing but we have a transaction hash,
    // try to extract the contract address from the error context
    if (error.message.includes('invalid address') && error.transactionHash) {
      console.log(`Attempting to recover contract from transaction hash: ${error.transactionHash}`);
      
      // Retry with increasing wait times
      const maxRetries = 5;
      const baseWaitTime = 15000; // 15 seconds base wait
      
      for (let attempt = 1; attempt <= maxRetries; attempt++) {
        const waitTime = baseWaitTime * attempt; // 15s, 30s, 45s, 60s, 75s
        console.log(`Attempt ${attempt}/${maxRetries}: Waiting ${waitTime/1000} seconds for transaction to be mined...`);
        await new Promise(resolve => setTimeout(resolve, waitTime));
        
        try {
          // Use raw JSON-RPC call to avoid ethers.js formatting
          const receipt = await ethers.provider.send('eth_getTransactionReceipt', [error.transactionHash]);
          
          if (receipt) {
            console.log(`✅ Transaction found! Status: ${receipt.status}`);
            console.log(`Gas used: ${receipt.gasUsed}`);
            
            // Check if transaction was successful
            if (receipt.status === '0x0') {
              console.error('❌ Transaction failed/reverted');
              // Try to get revert reason
              try {
                const tx = await ethers.provider.send('eth_getTransactionByHash', [error.transactionHash]);
                console.log('Transaction details:', {
                  to: tx.to,
                  value: tx.value,
                  gasLimit: tx.gas,
                  gasPrice: tx.gasPrice
                });
              } catch (txError) {
                console.log('Could not fetch transaction details:', txError.message);
              }
              throw new Error(`Transaction ${error.transactionHash} failed/reverted`);
            }
            
            if (receipt.contractAddress) {
              console.log(`✅ Recovered contract address: ${receipt.contractAddress}`);
              const contract = Contract.attach(receipt.contractAddress);
              
              await verifyOnTenderly(name, contract.address);
              await storeContractDeployment(
                isVault,
                artifactName || name,
                contract.address,
                name,
                args
              );
              
              return contract;
            } else {
              console.log('⚠️  Transaction successful but no contract address - this might not be a contract creation transaction');
              break; // Exit retry loop, this won't get better with more retries
            }
          } else {
            console.log(`⏳ Attempt ${attempt}: Transaction receipt not found - transaction may not be mined yet`);
            if (attempt === maxRetries) {
              console.log('❌ Max retries reached. Transaction may have been dropped or is taking unusually long to mine.');
            }
            // Continue to next retry attempt
          }
        } catch (recoveryError) {
          console.error(`❌ Attempt ${attempt} failed:`, recoveryError.message);
          if (attempt === maxRetries) {
            console.error('❌ All recovery attempts failed');
          }
          // Continue to next retry attempt unless it's the last one
        }
      }
    }
    throw error;
  }
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

/**
 * Deploys core contracts including staking, locking LP, treasury, and actions
 * @param {Object} config - The network configuration object
 * @param {string} poolType - The pool type ('eth' or 'usdc')
 * @param {string} poolKey - The key of the pool in config.Core (e.g., 'PoolV3_LpUSD')
 * @param {Array<string>} [customPositionActions] - Optional custom list of position actions to deploy
 */
async function deployPoolCore(config, poolType, poolKey, customPositionActions) {
  return await deployPoolCoreSelective(config, poolType, poolKey, customPositionActions, {});
}

/**
 * Deploys core contracts with selective deployment options
 * @param {Object} config - The network configuration object
 * @param {string} poolType - The pool type ('eth' or 'usdc')
 * @param {string} poolKey - The key of the pool in config.Core (e.g., 'PoolV3_LpUSD')
 * @param {Array<string>} [customPositionActions] - Optional custom list of position actions to deploy
 * @param {Object} [options] - Deployment options
 * @param {boolean} [options.skipStaking] - Skip staking contract deployment
 * @param {boolean} [options.skipLocking] - Skip locking contract deployment
 * @param {boolean} [options.skipTreasury] - Skip treasury deployment
 * @param {boolean} [options.skipVaultRegistry] - Skip vault registry deployment
 * @param {boolean} [options.skipActions] - Skip actions deployment
 * @param {Object} [options.existingContracts] - Existing contract addresses to use instead of deploying
 */
async function deployPoolCoreSelective(config, poolType, poolKey, customPositionActions, options = {}) {
  const signer = await getSignerAddress();
  
  if (hre.network.name == 'tenderly') {
    await ethers.provider.send('tenderly_setBalance', [[signer], ethers.utils.hexValue(toWad('100').toHexString())]);
  }

  const addressProviderV3 = await attachContract('AddressProviderV3', config.Core.AddressProviderV3);
  
  // Use the poolKey parameter to get the pool address
  if (!config.Core[poolKey]) {
    throw new Error(`Pool key "${poolKey}" not found in config.Core`);
  }
  const pool = await attachContract('PoolV3', config.Core[poolKey]);
  console.log(`Using pool ${poolKey} at address: ${pool.address}`);

  let stakingLp, lockLp;
  
  // Deploy or attach staking and locking contracts
  if (options.skipStaking && options.skipLocking) {
    console.log('Skipping staking and locking contract deployment');
    // Use existing contracts if provided
    if (options.existingContracts?.stakingLp) {
      stakingLp = await attachContract('StakingLPEth', options.existingContracts.stakingLp);
      console.log(`Using existing staking contract at: ${stakingLp.address}`);
    }
    if (options.existingContracts?.lockLp) {
      lockLp = await attachContract('Locking', options.existingContracts.lockLp);
      console.log(`Using existing locking contract at: ${lockLp.address}`);
    }
  } else {
    const deployed = await deployStakingAndLockingLP(pool, poolType);
    stakingLp = deployed.stakingLp;
    lockLp = deployed.lockLp;
  }
  
  console.log('staking lp property name', `stakingLp${poolType.toUpperCase()}`);
  
  let treasury;
  if (options.skipTreasury) {
    console.log('Skipping treasury deployment');
    if (options.existingContracts?.treasury) {
      treasury = await attachContract('Treasury', options.existingContracts.treasury);
      console.log(`Using existing treasury at: ${treasury.address}`);
    }
  } else {
    // Use pool-specific treasury config if available, otherwise fall back to default
    const treasuryConfigKey = `Treasury_${poolType}`;
    const treasuryConfig = config.Core[treasuryConfigKey] || config.Core.Treasury;
    
    if (!treasuryConfig) {
      throw new Error(`No treasury configuration found for pool type "${poolType}". Expected "${treasuryConfigKey}" or "Treasury" in config.Core`);
    }
    
    const treasuryReplaceParams = {
      'deployer': signer,
      [`stakingLp${poolType.toUpperCase()}`]: stakingLp?.address || options.existingContracts?.stakingLp || ethers.constants.AddressZero,
      'stakingLpToken': stakingLp?.address || options.existingContracts?.stakingLp || ethers.constants.AddressZero
    };

    const { payees, shares, admin } = replaceParams(treasuryConfig.constructorArguments, treasuryReplaceParams);
    treasury = await deployContract('Treasury', `Treasury_${poolType}`, false, payees, shares, admin);
    
    await pool.setTreasury(treasury.address);
    console.log(`Treasury deployed and set in pool`);
  }

  let vaultRegistry;
  if (options.skipVaultRegistry) {
    console.log('Skipping vault registry deployment');
    if (options.existingContracts?.vaultRegistry) {
      vaultRegistry = await attachContract('VaultRegistry', options.existingContracts.vaultRegistry);
      console.log(`Using existing vault registry at: ${vaultRegistry.address}`);
    } else if (config.Core.VaultRegistry) {
      vaultRegistry = await attachContract('VaultRegistry', config.Core.VaultRegistry);
      console.log(`Using vault registry from config at: ${vaultRegistry.address}`);
    }
  } else {
    // Deploy new vault registry
    vaultRegistry = await deployContract('VaultRegistry', `VaultRegistry_${poolType}`, false);
    console.log(`VaultRegistry deployed at: ${vaultRegistry.address}`);
  }

  let flashlender, proxyRegistry;
  if (options.skipActions) {
    console.log('Skipping actions deployment');
    if (options.existingContracts?.flashlender) {
      flashlender = await attachContract('Flashlender', options.existingContracts.flashlender);
      console.log(`Using existing flashlender at: ${flashlender.address}`);
    }
    if (options.existingContracts?.proxyRegistry) {
      proxyRegistry = await attachContract('PRBProxyRegistry', options.existingContracts.proxyRegistry);
      console.log(`Using existing proxy registry at: ${proxyRegistry.address}`);
    }
  } else {
    const deployed = await deployActions(pool, vaultRegistry, poolType, config, customPositionActions);
    flashlender = deployed.flashlender;
    proxyRegistry = deployed.proxyRegistry;
  }

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
 * @param {Object} config - The network configuration object
 * @param {Array<string>} [customPositionActions] - Optional custom list of position actions to deploy
 * @returns {Object} The deployed action contracts
 */
async function deployActions(pool, vaultRegistry, poolType, config, customPositionActions) {
  const flashlenderName = `Flashlender_${poolType}`;
  const flashlenderConfig = config.Core[flashlenderName];
  const flashlender = await deployContract(
    'Flashlender',
    flashlenderName,
    false,
    pool.address,
    flashlenderConfig.constructorArguments.protocolFee_
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
  if (customPositionActions) {
    await deployCustomPositionActions(flashlender, swapAction, poolAction, vaultRegistry, poolType, config, customPositionActions);
  } else {
    await deployPositionActions(flashlender, swapAction, poolAction, vaultRegistry, poolType, config);
  }

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
 * Deploys custom position action contracts
 * @param {Contract} flashlender - The flashlender contract
 * @param {Contract} swapAction - The swap action contract
 * @param {Contract} poolAction - The pool action contract
 * @param {Contract} vaultRegistry - The vault registry contract
 * @param {string} poolType - The pool type ('eth' or 'usdc')
 * @param {Object} config - The network configuration object
 * @param {Array<string>} customActions - List of position action contracts to deploy
 */
async function deployCustomPositionActions(flashlender, swapAction, poolAction, vaultRegistry, poolType, config, customActions) {
  for (const action of customActions) {
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
      oracleType+'_'+key,
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
 * @returns {Array} Deployed pools
 */
async function deployPools(config, addressProviderV3) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING POOLS
//////////////////////////////////////////////////////////////*/
  `);
  
  const pools = [];
  
  // Deploy each pool individually using deployPoolWithType
  for (const [poolKey, poolConfig] of Object.entries(config.Pools)) {
    const pool = await deployPoolWithType(config, addressProviderV3, '', poolKey, poolConfig);
    pools.push(pool);
  }
  
  return pools;
}

/**
 * Deploys a single pool with its interest rate model and a pool type suffix
 * @param {Object} config - The network configuration object (for globals like Gearbox config)
 * @param {Contract} addressProviderV3 - The address provider contract
 * @param {string} poolType - The pool type identifier (e.g., 'eth', 'usdc')
 * @param {string} poolKey - The key identifier for the pool
 * @param {Object} poolConfig - The specific pool configuration
 * @returns {Object} The deployed pool
 */
async function deployPoolWithType(config, addressProviderV3, poolType, poolKey, poolConfig) {
  console.log(`
/*//////////////////////////////////////////////////////////////
               DEPLOYING POOL: ${poolKey} (${poolType.toUpperCase()})
//////////////////////////////////////////////////////////////*/
  `);

  // Use pool type in the deployment names
  const interestModelName = `LinearInterestRateModelV3_${poolKey}`;
  const poolName = `PoolV3_${poolKey}`;

  // Deploy LinearInterestRateModelV3 for this pool
  const LinearInterestRateModelV3 = await deployContract(
    'LinearInterestRateModelV3',
    interestModelName,
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
    poolName,
    false,
    poolConfig.wrappedToken,
    addressProviderV3.address,
    poolConfig.underlier,
    LinearInterestRateModelV3.address,
    poolConfig.initialDebtCeiling || config.Core.Gearbox.initialGlobalDebtCeiling,
    poolConfig.name,
    poolConfig.symbol
  );

  console.log(`Pool ${poolKey} (${poolType}) Deployed at ${PoolV3.address}`);
  
  // Verify on Tenderly
  await verifyOnTenderly('LinearInterestRateModelV3', LinearInterestRateModelV3.address);
  await verifyOnTenderly('PoolV3', PoolV3.address);

  return PoolV3;
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

/**
 * Generates raw transactions for adding vaults to an existing gauge (for multisig execution)
 * @param {string} poolAddress - The address of the pool
 * @param {Object} CONFIG_NETWORK - The network configuration
 * @param {boolean} executeTransactions - Whether to execute transactions (default: false)
 * @returns {Promise<Array>} - Array of transaction objects for multisig execution
 */
async function deployGauge(poolAddress, CONFIG_NETWORK, executeTransactions = false) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        ${executeTransactions ? 'DEPLOYING' : 'GENERATING'} GAUGE TRANSACTIONS
//////////////////////////////////////////////////////////////*/
  `);

  if (!poolAddress) {
    console.log('No pool address defined for gauge');
    return [];
  }

  const gaugeV3 = await attachContract('GaugeV3', CONFIG_NETWORK.Core.GaugeV3);
  const poolQuotaKeeperV3 = await attachContract('PoolQuotaKeeperV3', CONFIG_NETWORK.Core.PoolQuotaKeeperV3);
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));

  const transactions = [];

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
      console.log(`${executeTransactions ? 'Adding' : 'Preparing'} vault ${name} to gauge at address ${vault.address}`);
      const tokenAddress = await vault.token();
      
      const minRate = vaultMetadata.quotas.minRate;
      const maxRate = vaultMetadata.quotas.maxRate;

      // Generate transaction for setting Credit Manager in QuotaKeeper
      const setCreditManagerData = poolQuotaKeeperV3.interface.encodeFunctionData(
        'setCreditManager',
        [tokenAddress, vault.address]
      );

      transactions.push({
        to: poolQuotaKeeperV3.address,
        data: setCreditManagerData,
        value: '0',
        description: `Set Credit Manager in QuotaKeeper for token: ${tokenAddress}`,
        functionName: 'setCreditManager',
        parameters: {
          tokenAddress,
          vaultAddress: vault.address
        }
      });

      // Generate transaction for adding quota token to GaugeV3
      const addQuotaTokenData = gaugeV3.interface.encodeFunctionData(
        'addQuotaToken',
        [tokenAddress, minRate, maxRate]
      );

      transactions.push({
        to: gaugeV3.address,
        data: addQuotaTokenData,
        value: '0',
        description: `Add quota token to GaugeV3 for token: ${tokenAddress} (minRate: ${minRate}, maxRate: ${maxRate})`,
        functionName: 'addQuotaToken',
        parameters: {
          tokenAddress,
          minRate,
          maxRate
        }
      });

      if (executeTransactions) {
        console.log('Setting Credit Manager in QuotaKeeper for token:', tokenAddress);
        await poolQuotaKeeperV3.setCreditManager(tokenAddress, vault.address);
        console.log('Set Credit Manager in QuotaKeeper for token:', tokenAddress);
      
      console.log('Setting quota rates for token:', tokenAddress, 'minRate:', minRate, 'maxRate:', maxRate);
      await gaugeV3.addQuotaToken(tokenAddress, minRate, maxRate);
      console.log('Added quota token to GaugeV3 for token:', tokenAddress);

      // Update the gauge status
      deployment.vaults[name].addedToGauge = true;
      fs.writeFileSync(deploymentFilePath, JSON.stringify(deployment, null, 2));
      }
    } else {
      console.log(`${name} already added to gauge or not ready for gauge, skipping`);
    }
  }

  // Generate transaction for unfreezing the epoch in Gauge
  const setFrozenEpochData = gaugeV3.interface.encodeFunctionData(
    'setFrozenEpoch',
    [false]
  );

  transactions.push({
    to: gaugeV3.address,
    data: setFrozenEpochData,
    value: '0',
    description: 'Set frozen epoch to false in GaugeV3',
    functionName: 'setFrozenEpoch',
    parameters: {
      frozen: false
    }
  });

  if (executeTransactions) {
  // Unfreeze the epoch in Gauge
  await gaugeV3.setFrozenEpoch(false);
  console.log('Set frozen epoch to false in GaugeV3');
  console.log('Gauge and related configurations have been set.');
  } else {
    console.log(`Generated ${transactions.length} transactions for multisig execution:`);
    transactions.forEach((tx, index) => {
      console.log(`\n${index + 1}. ${tx.description}`);
      console.log(`   To: ${tx.to}`);
      console.log(`   Data: ${tx.data}`);
      console.log(`   Value: ${tx.value}`);
    });
  }

  return transactions;
}

module.exports = {
  getSignerAddress,
  getDeploymentFilePath,
  storeContractDeployment,
  deployContract,
  isContractDeployed,
  getDeployedContract,
  attachContract,
  getGasOptions,
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
  deployPoolCoreSelective,
  deployStakingAndLockingLP,
  deployActions,
  deployPositionActions,
  deployCustomPositionActions,
  deployVaultOracle,
  registerVaults,
  deployPools,
  deployPoolWithType,
  impersonateAccount,
  stopImpersonatingAccount,
  fundAccount,
  deployGauge
}; 