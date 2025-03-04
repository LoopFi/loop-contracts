const fs = require('fs');
const path = require('path');

/**
 * Gets the network name from Hardhat Runtime Environment
 * @returns {string} The network name (e.g., 'mainnet', 'arbitrum', etc.)
 */
function getNetworkName() {
  // When running with Hardhat, use the network from hre
  try {
    const hre = require('hardhat');
    if (hre && hre.network && hre.network.name) {
      return hre.network.name;
    }
  } catch (e) {
    // Ignore error if hardhat is not available
  }
  
  return process.env.CONFIG_NETWORK || 
         process.argv.find(arg => arg.startsWith('--network='))?.split('=')[1] || 
         'mainnet';
}

/**
 * Gets the config type from environment variables
 * @returns {string} The config type (e.g., 'usdc', 'eth', etc.)
 */
function getConfigType() {
  return process.env.CONFIG_TYPE || '';
}

/**
 * Gets the deployment type from environment variables
 * @returns {string} The deployment type (e.g., 'vault', 'pool', etc.)
 */
function getDeploymentType() {
  return process.env.DEPLOY_TYPE || '';
}

/**
 * Loads the appropriate configuration based on network and config type
 * @param {string} configType - The type of config to load (e.g., 'usdc', 'eth')
 * @returns {Object} The loaded configuration
 */
function loadConfig(configType = '') {
  const network = getNetworkName();
  
  console.log(`Loading config for network: ${network}, config type: ${configType || 'default'}`);
  
  // Try to load config in order of specificity
  const configPaths = [
    configType && network ? `config_${configType}_${network}.js` : null,
    configType ? `config_${configType}.js` : null,
    network ? `config_${network}.js` : null,
    'config.js'
  ].filter(Boolean);
  
  for (const configPath of configPaths) {
    const fullPath = path.join(__dirname, '..', configPath);
    if (fs.existsSync(fullPath)) {
      console.log(`Using config from ${configPath}`);
      return require(fullPath);
    }
  }
  
  console.warn('No config file found, using empty config');
  return {};
}

module.exports = {
  getNetworkName,
  getConfigType,
  getDeploymentType,
  loadConfig
}; 