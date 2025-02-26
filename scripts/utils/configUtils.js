const fs = require('fs');
const path = require('path');

/**
 * Gets the network name from command line arguments or environment variables
 * @returns {string} The network name (e.g., 'mainnet', 'arbitrum', etc.)
 */
function getNetworkName() {
  return process.env.CONFIG_NETWORK || 
         process.argv.find(arg => arg.startsWith('--network='))?.split('=')[1] || 
         'mainnet';
}

/**
 * Gets the config type from command line arguments
 * @returns {string} The config type (e.g., 'usdc', 'eth', etc.)
 */
function getConfigType() {
  return process.argv.find(arg => arg.startsWith('--config='))?.split('=')[1] || '';
}

/**
 * Gets the deployment type from command line arguments
 * @returns {string} The deployment type (e.g., 'vault', 'pool', etc.)
 */
function getDeploymentType() {
  return process.argv.find(arg => arg.startsWith('--deploy='))?.split('=')[1] || '';
}

/**
 * Loads the appropriate configuration file based on network and config type
 * @returns {Object} The loaded configuration object
 */
function loadConfig() {
  const network = getNetworkName();
  const configType = getConfigType();
  
  // First try to load network-specific config with config type
  if (configType) {
    try {
      return require(`../config_${configType}_${network}.js`);
    } catch (e) {
      console.log(`Config file for type ${configType} and network ${network} not found, trying config_${configType}.js`);
      try {
        return require(`../config_${configType}.js`);
      } catch (e) {
        console.log(`Config file for type ${configType} not found, falling back to network config`);
      }
    }
  }
  
  // Try to load network-specific config
  try {
    return require(`../config_${network}.js`);
  } catch (e) {
    console.log(`Config file for network ${network} not found, using default config.js`);
    return require('../config.js');
  }
}

module.exports = {
  getNetworkName,
  getConfigType,
  getDeploymentType,
  loadConfig
}; 