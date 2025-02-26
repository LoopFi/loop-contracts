const fs = require('fs');
const path = require('path');
const { ethers } = require('hardhat');

async function getSignerAddress() {
  return (await ethers.getSigners())[0].address;
}

async function getDeploymentFilePath() {
  return path.join(__dirname, '..', `deployment-${hre.network.name}.json`);
}

async function storeContractDeployment(isVault, name, address, artifactName, constructorArgs = []) {
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  
  if (isVault) {
    if (deployment.vaults == undefined) deployment.vaults = {};
    deployment.vaults[name] = { address, artifactName, constructorArgs };
  } else {
    if (deployment.core == undefined) deployment.core = {};
    deployment.core[name] = { address, artifactName, constructorArgs };
  }
  
  fs.writeFileSync(deploymentFilePath, JSON.stringify(deployment, null, 2));
}

async function deployContract(name, artifactName, isVault, ...args) {
  console.log(`Deploying ${artifactName || name}... {${args.map((v) => v.toString()).join(', ')}}}`);
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
    args.map(arg => arg.toString())
  );
  
  return contract;
}

async function isContractDeployed(name) {
  const deploymentFilePath = await getDeploymentFilePath();
  if (!fs.existsSync(deploymentFilePath)) return false;
  
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  
  return (deployment.core && deployment.core[name]) || 
         (deployment.vaults && deployment.vaults[name]);
}

async function getDeployedContract(name) {
  const deploymentFilePath = await getDeploymentFilePath();
  if (!fs.existsSync(deploymentFilePath)) return null;
  
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  
  const contractData = (deployment.core && deployment.core[name]) || 
                      (deployment.vaults && deployment.vaults[name]);

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
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  const contracts = {};
  for (let [name, { address, artifactName }] of Object.entries({ ...deployment.core, ...deployment.vaults })) {
    if (artifactName.includes('IWeightedPool')) continue;
    contracts[name] = (await ethers.getContractFactory(artifactName)).attach(address);
  }
  return contracts;
}

async function loadDeployedVaults() {
  console.log('Loading deployed vaults...');
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  const contracts = {};
  for (let [name, { address, artifactName }] of Object.entries({ ...deployment.vaults })) {
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
  verifyOnTenderly
}; 