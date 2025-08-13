const hre = require('hardhat');
const {
  getDeployedContract,
  attachContract,
  deployContract,
  getSignerAddress
} = require('./utils/deployUtils');
const { 
  loadConfig 
} = require('./utils/configUtils');

// Load the network-specific config
const CONFIG_TYPE = 'eth';
const CONFIG_NETWORK = loadConfig(CONFIG_TYPE);

const { ethers } = require('hardhat');

// Function to deploy mock Chainlink oracles for all vault collateral tokens
async function deployMockOraclesForVaultTokens() {
  console.log(`
/*//////////////////////////////////////////////////////////////
              DEPLOYING MOCK ORACLES FOR VAULT TOKENS
//////////////////////////////////////////////////////////////*/
  `);

  // Get the VaultRegistry contract
  let vaultRegistry;
  const vaultRegistryInfo = await getDeployedContract('VaultRegistry');
  
  if (vaultRegistryInfo) {
    vaultRegistry = await ethers.getContractAt('VaultRegistry', vaultRegistryInfo.address);
  } else if (CONFIG_NETWORK.Core.VaultRegistry) {
    console.log('Attaching VaultRegistry from config address...');
    vaultRegistry = await attachContract('VaultRegistry', CONFIG_NETWORK.Core.VaultRegistry);
  } else {
    throw new Error('VaultRegistry not found. Please deploy it first.');
  }

  console.log('Using VaultRegistry at:', vaultRegistry.address);

  // Get all registered vaults
  const vaults = await vaultRegistry.getVaults();
  console.log(`Found ${vaults.length} registered vaults`);

  if (vaults.length === 0) {
    console.log('No vaults registered. Nothing to do.');
    return;
  }

  // Set to track unique token addresses
  const uniqueTokens = new Set();
  const tokenToVaultMap = new Map();

  // Extract token addresses from all vaults
  for (let i = 0; i < vaults.length; i++) {
    const vaultAddress = vaults[i];
    console.log(`\nProcessing vault ${i + 1}/${vaults.length}: ${vaultAddress}`);
    
    try {
      // Get vault contract instance
      const vault = await ethers.getContractAt('CDPVault', vaultAddress);
      
      // Get the collateral token address
      const tokenAddress = await vault.token();
      console.log(`  - Collateral token: ${tokenAddress}`);
      
      // Add to our tracking
      uniqueTokens.add(tokenAddress);
      
      if (!tokenToVaultMap.has(tokenAddress)) {
        tokenToVaultMap.set(tokenAddress, []);
      }
      tokenToVaultMap.get(tokenAddress).push(vaultAddress);
      
    } catch (error) {
      console.error(`  ❌ Error processing vault ${vaultAddress}:`, error.message);
    }
  }

  console.log(`\nFound ${uniqueTokens.size} unique collateral tokens:`);
  uniqueTokens.forEach(token => {
    const vaultCount = tokenToVaultMap.get(token).length;
    console.log(`  - ${token} (used by ${vaultCount} vault${vaultCount > 1 ? 's' : ''})`);
  });

  // Deploy mock oracles for each unique token
  const deployedOracles = new Map();
  const signer = await getSignerAddress();
  
  console.log('\n🔧 Deploying mock Chainlink oracles...');
  
  for (const tokenAddress of uniqueTokens) {
    console.log(`\nDeploying mock oracle for token: ${tokenAddress}`);
    
    try {
      // Deploy MockChainlinkOracle with 18 decimals and price of 1e18 (1 USD)
      const mockOracle = await deployContract(
        'src/test/MockChainlinkOracle.sol:MockChainlinkOracle',
        `MockChainlinkOracle_${tokenAddress.slice(-8)}`, // Use last 8 chars of address for unique name
        false,
        18, // decimals
        ethers.utils.parseEther("1") // price: 1e18 (1 USD)
      );
      
      deployedOracles.set(tokenAddress, mockOracle.address);
      console.log(`  ✅ Deployed at: ${mockOracle.address}`);
      
    } catch (error) {
      console.error(`  ❌ Failed to deploy oracle for ${tokenAddress}:`, error.message);
    }
  }

  // Grant VAULT_MANAGER_ROLE to deployer if needed
  console.log('\n🔑 Checking permissions...');
  const VAULT_MANAGER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("VAULT_MANAGER_ROLE"));
  const hasRole = await vaultRegistry.hasRole(VAULT_MANAGER_ROLE, signer);
  
  if (!hasRole) {
    console.log('Granting VAULT_MANAGER_ROLE to deployer...');
    try {
      await vaultRegistry.grantRole(VAULT_MANAGER_ROLE, signer);
      console.log('✅ VAULT_MANAGER_ROLE granted');
    } catch (error) {
      console.error('❌ Failed to grant VAULT_MANAGER_ROLE:', error.message);
      console.log('Please ensure the deployer has DEFAULT_ADMIN_ROLE on VaultRegistry');
      return;
    }
  } else {
    console.log('✅ Deployer already has VAULT_MANAGER_ROLE');
  }

  // Set oracles for all tokens
  console.log('\n🔗 Setting token oracles in VaultRegistry...');
  
  for (const [tokenAddress, oracleAddress] of deployedOracles) {
    console.log(`Setting oracle for token ${tokenAddress}...`);
    
    try {
      await vaultRegistry.setTokenOracle(tokenAddress, oracleAddress);
      console.log(`  ✅ Oracle set: ${tokenAddress} -> ${oracleAddress}`);
      
      // Verify the oracle was set correctly
      const setOracle = await vaultRegistry.getTokenOracle(tokenAddress);
      if (setOracle.toLowerCase() === oracleAddress.toLowerCase()) {
        console.log(`  ✅ Verified oracle is set correctly`);
      } else {
        console.log(`  ⚠️  Warning: Oracle verification failed`);
      }
      
    } catch (error) {
      console.error(`  ❌ Failed to set oracle for ${tokenAddress}:`, error.message);
    }
  }

  // Summary
  console.log('\n📊 SUMMARY:');
  console.log(`- Processed ${vaults.length} vaults`);
  console.log(`- Found ${uniqueTokens.size} unique collateral tokens`);
  console.log(`- Deployed ${deployedOracles.size} mock oracles`);
  console.log(`- All oracles return a fixed price of 1.0 USD (1e18)`);
  
  console.log('\n✅ Mock oracle deployment completed!');
  
  return {
    vaultRegistry: vaultRegistry.address,
    vaultCount: vaults.length,
    tokenCount: uniqueTokens.size,
    deployedOracles: Object.fromEntries(deployedOracles)
  };
}

// Standalone script to deploy mock Chainlink oracles for all vault tokens
async function main() {
  console.log(`
/*//////////////////////////////////////////////////////////////
            MOCK ORACLES DEPLOYMENT UTILITY
//////////////////////////////////////////////////////////////*/
  `);
  
  console.log('Network:', hre.network.name);
  console.log('Chain ID:', hre.network.config.chainId || 'unknown');
  console.log('');
  
  console.log('This script will:');
  console.log('1. 🔍 Find all registered vaults in VaultRegistry');
  console.log('2. 📋 Extract unique collateral token addresses');
  console.log('3. 🏭 Deploy MockChainlinkOracle for each token');
  console.log('4. 🔗 Set oracles in VaultRegistry using setTokenOracle');
  console.log('5. ✅ Verify all oracles are set correctly');
  console.log('');
  console.log('All mock oracles will return a fixed price of 1.0 USD (1e18)');
  console.log('');
  
  const result = await deployMockOraclesForVaultTokens();
  
  if (result) {
    console.log('\n🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!');
    console.log('\nDeployment Details:');
    console.log(`- VaultRegistry: ${result.vaultRegistry}`);
    console.log(`- Vaults processed: ${result.vaultCount}`);
    console.log(`- Unique tokens: ${result.tokenCount}`);
    console.log(`- Oracles deployed: ${Object.keys(result.deployedOracles).length}`);
    
    console.log('\nDeployed Oracles:');
    for (const [token, oracle] of Object.entries(result.deployedOracles)) {
      console.log(`  ${token} -> ${oracle}`);
    }
  }
  
  console.log('\n✅ Script completed!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('❌ Script failed:', error);
    process.exit(1);
  });
