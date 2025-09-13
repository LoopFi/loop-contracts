const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const { promisify } = require('util');

const execAsync = promisify(exec);

// Load deployment data
function loadDeploymentData(network = 'bitlayer') {
  const deploymentPath = path.join(__dirname, `deployment-${network}.json`);
  if (!fs.existsSync(deploymentPath)) {
    console.error(`❌ Deployment file not found: ${deploymentPath}`);
    console.error('💡 Please run deployment first or check the network name.');
    process.exit(1);
  }
  console.log(`📄 Loading deployment data from: deployment-${network}.json`);
  return JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
}

// Contract path mappings based on artifact names
const CONTRACT_PATHS = {
  // Core contracts (from npm packages)
  'ACL': '@gearbox-protocol/core-v2/contracts/core/ACL.sol:ACL',
  'AddressProviderV3': '@gearbox-protocol/core-v3/contracts/core/AddressProviderV3.sol:AddressProviderV3',
  'ContractsRegister': '@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol:ContractsRegister',
  'LinearInterestRateModelV3': '@gearbox-protocol/core-v3/contracts/pool/LinearInterestRateModelV3.sol:LinearInterestRateModelV3',
  
  // Local contracts (from src/)
  'PoolV3': 'src/PoolV3.sol:PoolV3',
  'PoolQuotaKeeperV3': 'src/quotas/PoolQuotaKeeperV3.sol:PoolQuotaKeeperV3',
  'GaugeV3': 'src/quotas/GaugeV3.sol:GaugeV3',
  'LoopVoter': 'src/quotas/LoopVoter.sol:LoopVoter',
  'PushOracle': 'src/oracle/PushOracle.sol:PushOracle',
  'CDPVault': 'src/CDPVault.sol:CDPVault',
  'Treasury': 'src/Treasury.sol:Treasury',
  'VaultRegistry': 'src/VaultRegistry.sol:VaultRegistry',
  'Flashlender': 'src/Flashlender.sol:Flashlender',
  
  // Staking contracts
  'StakingLPEth': 'src/StakingLPEth.sol:StakingLPEth',
  'Locking': 'src/Locking.sol:Locking',
  
  // Proxy contracts
  'PRBProxyRegistry': 'src/prb-proxy/PRBProxyRegistry.sol:PRBProxyRegistry',
  
  // Action contracts
  'SwapAction': 'src/proxy/SwapAction.sol:SwapAction',
  'PoolAction': 'src/proxy/PoolAction.sol:PoolAction',
  'PositionAction20': 'src/proxy/PositionAction20.sol:PositionAction20',
  'PositionAction4626': 'src/proxy/PositionAction4626.sol:PositionAction4626',
  'PositionActionPendle': 'src/proxy/PositionActionPendle.sol:PositionActionPendle',
  'PositionActionTranchess': 'src/proxy/PositionActionTranchess.sol:PositionActionTranchess',
  
  // OpenZeppelin contracts
  'ERC1967Proxy': '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy'
};

// Helper function to format constructor arguments for verification
function formatConstructorArgs(args) {
  if (!args || args.length === 0) return [];
  
  return args.map(arg => {
    if (Array.isArray(arg)) {
      // Handle arrays - flatten them for command line
      return arg.join(',');
    } else if (typeof arg === 'object' && arg !== null) {
      // Handle objects/structs - convert to comma-separated values
      return Object.values(arg).join(',');
    } else {
      // Handle primitive types
      return arg.toString();
    }
  });
}

// Special handling for CDPVault constructor arguments
function formatCDPVaultArgs(args) {
  if (args.length === 2 && Array.isArray(args[0]) && Array.isArray(args[1])) {
    // First array: CDPVaultConstants (pool, oracle, token, tokenScale)
    const constants = {
      pool: args[0][0],
      oracle: args[0][1], 
      token: args[0][2],
      tokenScale: args[0][3]
    };
    
    // Second array: CDPVaultConfig (debtFloor, liquidationRatio, liquidationPenalty, liquidationDiscount, roleAdmin, vaultAdmin, pauseAdmin)
    const config = {
      debtFloor: args[1][0],
      liquidationRatio: args[1][1],
      liquidationPenalty: args[1][2],
      liquidationDiscount: args[1][3],
      roleAdmin: args[1][4],
      vaultAdmin: args[1][5],
      pauseAdmin: args[1][6]
    };
    
    return [constants, config];
  }
  return args;
}

async function verifyContract(contractName, address, constructorArgs = [], contractPath = null, network = 'bitlayer') {
  console.log(`\n🔍 Verifying ${contractName} at ${address}...`);
  
  // Get contract path from artifact name or use provided path
  const contract = contractPath || CONTRACT_PATHS[contractName];
  
  if (!contract) {
    console.log(`⚠️  No contract path found for ${contractName}, skipping...`);
    return false;
  }
  
  try {
    // Special handling for CDPVault
    let processedArgs = constructorArgs;
    if (contractName === 'CDPVault') {
      processedArgs = formatCDPVaultArgs(constructorArgs);
    }
    
    // For contracts with complex constructor arguments, create an arguments file
    const hasComplexArgs = processedArgs.some(arg => 
      Array.isArray(arg) || (typeof arg === 'object' && arg !== null)
    );
    
    if (hasComplexArgs && processedArgs.length > 0) {
      // Create arguments file for complex types
      const fs = require('fs');
      const path = require('path');
      const argsFileName = `verify-args-${contractName}-${Date.now()}.js`;
      const argsFilePath = path.resolve(argsFileName); // Use absolute path
      
      console.log(`   Creating arguments file: ${argsFilePath}`);
      
      const argsFileContent = `module.exports = ${JSON.stringify(processedArgs, null, 2)};`;
      fs.writeFileSync(argsFilePath, argsFileContent);
      
      // Verify file was created
      if (!fs.existsSync(argsFilePath)) {
        throw new Error(`Failed to create arguments file: ${argsFilePath}`);
      }
      
      // Build verification command with arguments file
      const cmd = `npx hardhat verify --network ${network} --contract "${contract}" --constructor-args ${argsFileName} ${address}`;
      console.log(`   Command: ${cmd}`);
      
      try {
        const { stdout, stderr } = await execAsync(cmd);
        
        // Check for actual errors vs warnings
        const hasRealError = stderr && 
          !stderr.includes('Already Verified') && 
          !stderr.includes('Warning: SPDX license identifier') &&
          (stderr.includes('Error') || stderr.includes('Failed'));
        
        if (hasRealError) {
          throw new Error(stderr);
        }
        
        console.log(`✅ ${contractName} verified successfully!`);
        return true;
      } finally {
        // Clean up arguments file
        try {
          if (fs.existsSync(argsFilePath)) {
            fs.unlinkSync(argsFilePath);
            console.log(`   Cleaned up arguments file: ${argsFileName}`);
          }
        } catch (e) {
          console.log(`   Warning: Could not clean up arguments file: ${e.message}`);
        }
      }
    } else {
      // Build the verification command for simple arguments
      let cmd = `npx hardhat verify --network ${network}`;
      
      // Add contract path if available
      if (contract) {
        cmd += ` --contract "${contract}"`;
      }
      
      // Add address
      cmd += ` ${address}`;
      
      // Add constructor arguments
      if (processedArgs && processedArgs.length > 0) {
        const formattedArgs = formatConstructorArgs(processedArgs);
        const argsString = formattedArgs.map(arg => `"${arg}"`).join(' ');
        cmd += ` ${argsString}`;
      }
      
      console.log(`   Command: ${cmd}`);
      
      // Execute the command
      const { stdout, stderr } = await execAsync(cmd);
      
      // Check for actual errors vs warnings
      const hasRealError = stderr && 
        !stderr.includes('Already Verified') && 
        !stderr.includes('Warning: SPDX license identifier') &&
        (stderr.includes('Error') || stderr.includes('Failed'));
      
      if (hasRealError) {
        throw new Error(stderr);
      }
      
      console.log(`✅ ${contractName} verified successfully!`);
      return true;
    }
  } catch (error) {
    if (error.message.includes("Already Verified") || error.stdout?.includes("Already Verified")) {
      console.log(`✅ ${contractName} already verified`);
      return true;
    } else {
      console.error(`❌ Failed to verify ${contractName}:`, error.message);
      console.error(`   Address: ${address}`);
      console.error(`   Constructor args: ${JSON.stringify(constructorArgs)}`);
      return false;
    }
  }
}

async function verifyAllContracts(network = 'bitlayer') {
  console.log(`🚀 Starting ${network} contract verification...\n`);
  
  const deployment = loadDeploymentData(network);
  let successCount = 0;
  let totalCount = 0;
  
  // Function to verify contracts from any section
  async function verifySection(sectionName, contracts) {
    console.log(`\n📋 Verifying ${sectionName}...`);
    
    for (const [contractName, contractData] of Object.entries(contracts)) {
      if (contractData.address && contractData.artifactName) {
        totalCount++;
        
        // Use constructor args from deployment data
        const constructorArgs = contractData.constructorArgs || [];
        
        console.log(`\n📝 Contract: ${contractName}`);
        console.log(`   Artifact: ${contractData.artifactName}`);
        console.log(`   Address: ${contractData.address}`);
        console.log(`   Constructor Args: ${JSON.stringify(constructorArgs)}`);
        
        if (await verifyContract(contractData.artifactName, contractData.address, constructorArgs, null, network)) {
          successCount++;
        }
      }
    }
  }
  
  // Verify all sections that exist in the deployment
  const sections = [
    { name: 'Core Contracts', key: 'core' },
    { name: 'Pool Contracts', key: 'pools' },
    { name: 'Oracle Contracts', key: 'oracles' },
    { name: 'Vault Contracts', key: 'vaults' },
    { name: 'Action Contracts', key: 'actions' },
    { name: 'Staking Contracts', key: 'staking' },
    { name: 'Treasury Contracts', key: 'treasury' },
    { name: 'Auxiliary Contracts', key: 'auxiliary' }
  ];
  
  for (const section of sections) {
    if (deployment[section.key] && Object.keys(deployment[section.key]).length > 0) {
      await verifySection(section.name, deployment[section.key]);
    }
  }
  
  // Summary
  console.log('\n' + '='.repeat(60));
  console.log(`📊 Verification Summary for ${network.toUpperCase()}:`);
  console.log(`✅ Successfully verified: ${successCount}/${totalCount} contracts`);
  
  if (network === 'bitlayer') {
    console.log(`🌐 Explorer: https://www.btrscan.com/`);
  }
  
  if (successCount === totalCount) {
    console.log('\n🎉 All contracts verified successfully!');
  } else {
    console.log(`\n⚠️  ${totalCount - successCount} contracts failed verification`);
    console.log('💡 You can retry individual contracts or check the error messages above');
  }
  
  return { successCount, totalCount };
}

// Individual contract verification function
async function verifyIndividual(contractName, address, ...constructorArgs) {
  console.log(`🔍 Verifying individual contract: ${contractName}`);
  await verifyContract(contractName, address, constructorArgs);
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  
  if (args.length >= 2 && args[0] === 'individual') {
    // Individual verification: node verify_bitlayer.js individual ContractName 0xAddress [arg1] [arg2]...
    const [, contractName, address, ...constructorArgs] = args;
    await verifyIndividual(contractName, address, ...constructorArgs);
  } else if (args.length >= 1 && args[0] === 'network') {
    // Verify all contracts for specific network: node verify_bitlayer.js network mainnet
    const network = args[1] || 'bitlayer';
    await verifyAllContracts(network);
  } else {
    // Default: verify all contracts for bitlayer
    const network = args[0] || 'bitlayer';
    await verifyAllContracts(network);
  }
}

// Handle errors
main().catch((error) => {
  console.error('❌ Verification failed:', error);
  process.exit(1);
});

module.exports = {
  verifyContract,
  verifyAllContracts,
  CONTRACT_PATHS
};
