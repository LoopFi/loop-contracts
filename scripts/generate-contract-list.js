const fs = require('fs');
const path = require('path');

async function generateContractLists() {
  const deploymentDir = path.join(__dirname, '.');
  const allContracts = [['Chain', 'Address', 'Label']];
  const vaults = [['Chain', 'Address', 'Label']];
  const poolV3s = [['Chain', 'Address', 'Label']];
  
  // Read all deployment files
  const files = fs.readdirSync(deploymentDir);
  const deploymentFiles = files.filter(file => 
    file.startsWith('deployment-') && 
    file.endsWith('.json') &&
    !file.includes('local') &&
    !file.includes('tenderly')
  );

  for (const file of deploymentFiles) {
    let network = file.replace('deployment-', '').replace('.json', '');
    if (network === 'mainnet') {
      network = 'ethereum';
    }
    
    const deploymentPath = path.join(deploymentDir, file);
    
    if (fs.existsSync(deploymentPath)) {
      const deployment = JSON.parse(fs.readFileSync(deploymentPath));
      
      // Process core contracts
      if (deployment.core) {
        for (const [name, data] of Object.entries(deployment.core)) {
          const row = [network, data.address, `${name}_${network}`];
          allContracts.push(row);
          
          // Check for PoolV3s
          if (name.toLowerCase().includes('poolv3')) {
            poolV3s.push(row);
          }
        }
      }

      // Process vault contracts
      if (deployment.vaults) {
        for (const [name, data] of Object.entries(deployment.vaults)) {
          const row = [network, data.address, `${name}_${network}`];
          allContracts.push(row);
          
          // Check for any type of Vault
          if (name.includes('Vault')) {
            vaults.push(row);
          }
        }
      }
    }
  }

  // Write CSV files
  function writeCSV(rows, filename) {
    const csvContent = rows.map(row => row.join(',')).join('\n');
    const outputPath = path.join(__dirname, filename);
    fs.writeFileSync(outputPath, csvContent);
    console.log(`Generated: ${outputPath}`);
  }

  writeCSV(allContracts, 'watchlist_template.csv');
  writeCSV(vaults, 'watchlist_vaults.csv');
  writeCSV(poolV3s, 'watchlist_poolv3s.csv');
}

// Run the script
generateContractLists().catch(console.error); 