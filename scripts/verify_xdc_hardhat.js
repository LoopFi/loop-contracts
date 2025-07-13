const fs = require('fs');
const { exec } = require('child_process');
const path = require('path');

// Load deployment data
function loadDeploymentFile(filePath) {
  try {
    const data = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(data);
  } catch (error) {
    console.error(`Error loading deployment file: ${error.message}`);
    process.exit(1);
  }
}

// Execute hardhat verify command
function executeVerification(address, constructorArgs = []) {
  return new Promise((resolve, reject) => {
    const argsString = constructorArgs.map(arg => `"${arg}"`).join(' ');
    const command = `npx hardhat verify --network xdc ${address} ${argsString}`;
    
    console.log(`\nExecuting: ${command}`);
    
    exec(command, (error, stdout, stderr) => {
      if (error) {
        // Check if it's already verified
        if (stderr.includes('already verified') || stdout.includes('already verified')) {
          console.log(`✅ Contract ${address} is already verified`);
          resolve({ success: true, alreadyVerified: true });
        } else {
          console.error(`❌ Error verifying ${address}: ${error.message}`);
          resolve({ success: false, error: error.message });
        }
      } else {
        console.log(`✅ Successfully verified ${address}`);
        console.log(stdout);
        resolve({ success: true, alreadyVerified: false });
      }
    });
  });
}

// Wait function for delays between verifications
function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function verifyAllContracts() {
  const deploymentFile = 'scripts/deployment-xdc.json';
  console.log(`Loading deployment file: ${deploymentFile}`);
  
  const data = loadDeploymentFile(deploymentFile);
  
  let verified = 0;
  let failed = 0;
  let alreadyVerified = 0;
  
  console.log('\n🚀 Starting XDC contract verification with Hardhat...\n');
  
  // Process core contracts
  if (data.core) {
    console.log('📋 Processing core contracts...');
    
    for (const [name, contract] of Object.entries(data.core)) {
      if (!contract.address) {
        console.log(`⏭️  Skipping ${name} - no address found`);
        continue;
      }
      
      console.log(`\n🔍 Verifying ${name} at ${contract.address}...`);
      
      const result = await executeVerification(
        contract.address,
        contract.constructorArgs || []
      );
      
      if (result.success) {
        if (result.alreadyVerified) {
          alreadyVerified++;
        } else {
          verified++;
        }
      } else {
        failed++;
      }
      
      // Wait 3 seconds between verifications to avoid rate limiting
      console.log('⏳ Waiting 3 seconds before next verification...');
      await wait(3000);
    }
  }
  
  // Process vault contracts
  if (data.vaults) {
    console.log('\n🏦 Processing vault contracts...');
    
    for (const [name, contract] of Object.entries(data.vaults)) {
      if (!contract.address) {
        console.log(`⏭️  Skipping ${name} - no address found`);
        continue;
      }
      
      console.log(`\n🔍 Verifying ${name} at ${contract.address}...`);
      
      const result = await executeVerification(
        contract.address,
        contract.constructorArgs || []
      );
      
      if (result.success) {
        if (result.alreadyVerified) {
          alreadyVerified++;
        } else {
          verified++;
        }
      } else {
        failed++;
      }
      
      // Wait 3 seconds between verifications
      console.log('⏳ Waiting 3 seconds before next verification...');
      await wait(3000);
    }
  }
  
  // Process reward managers
  if (data.rewardManagers && Object.keys(data.rewardManagers).length > 0) {
    console.log('\n🎁 Processing reward manager contracts...');
    
    for (const [address, contract] of Object.entries(data.rewardManagers)) {
      if (!contract.address) {
        console.log(`⏭️  Skipping reward manager - no address found`);
        continue;
      }
      
      console.log(`\n🔍 Verifying reward manager for ${contract.vaultName || 'Unknown'} at ${contract.address}...`);
      
      const result = await executeVerification(
        contract.address,
        contract.constructorArgs || []
      );
      
      if (result.success) {
        if (result.alreadyVerified) {
          alreadyVerified++;
        } else {
          verified++;
        }
      } else {
        failed++;
      }
      
      // Wait 3 seconds between verifications
      console.log('⏳ Waiting 3 seconds before next verification...');
      await wait(3000);
    }
  }
  
  // Summary
  console.log('\n📊 Verification Summary:');
  console.log(`✅ Successfully verified: ${verified} contracts`);
  console.log(`🔄 Already verified: ${alreadyVerified} contracts`);
  console.log(`❌ Failed to verify: ${failed} contracts`);
  console.log(`📝 Total processed: ${verified + alreadyVerified + failed} contracts`);
  
  if (verified + alreadyVerified > 0) {
    console.log('\n🎉 All available contracts have been verified on XDC Network!');
    console.log('🔗 You can view them on XDCScan: https://xdcscan.com/');
  }
}

// Run the verification
verifyAllContracts().catch(console.error); 