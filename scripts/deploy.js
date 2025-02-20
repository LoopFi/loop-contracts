const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const axios = require('axios');
const { BigNumber } = require('ethers');
const { BalancerSDK, Network, PoolType } = require('@balancer-labs/sdk');

const network = process.env.CONFIG_NETWORK || process.argv.find(arg => arg.startsWith('--network='))?.split('=')[1] || 'mainnet';

const CONFIG = (() => {
  try {
    return require(`./config_${network}.js`);
  } catch (e) {
    console.log(`Config file for network ${network} not found, using default config.js`);
    return require('./config.js');
  }
})();

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);
const toWad = ethers.utils.parseEther;
const fromWad = ethers.utils.formatEther;
const toBytes32 = ethers.utils.formatBytes32String;

function convertBigNumberToString(value) {
  if (ethers.BigNumber.isBigNumber(value)) return value.toString();
  if (value instanceof Array) return value.map((v) => convertBigNumberToString(v));
  if (value instanceof Object) return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, convertBigNumberToString(v)]));
  return value;
}

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


async function getSignerAddress() {
  return (await (await ethers.getSigners())[0].getAddress());
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

async function getDeploymentFilePath() {
  return path.join(__dirname, '.', `deployment-${hre.network.name}.json`);
}

async function storeContractDeployment(isVault, name, address, artifactName, constructorArguments) {
  const deploymentFilePath = await getDeploymentFilePath();
  const deploymentFile = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  if (constructorArguments) constructorArguments = convertBigNumberToString(constructorArguments);
  if (isVault) {
    if (deploymentFile.vaults == undefined) deploymentFile.vaults = {};
    deploymentFile.vaults[name] = { address, artifactName, constructorArguments: constructorArguments || []};
  } else {
    if (deploymentFile.core == undefined) deploymentFile.core = {};
    deploymentFile.core[name] = { address, artifactName, constructorArguments: constructorArguments || []};
  }
  fs.writeFileSync(deploymentFilePath, JSON.stringify(deploymentFile, null, 2));
}

async function verifyAllDeployedContracts() {
  const deploymentFilePath = await getDeploymentFilePath();
  if (!fs.existsSync(deploymentFilePath)) {
    console.log('No deployment file found.');
    return;
  }

  const deployedContracts = JSON.parse(fs.readFileSync(deploymentFilePath));

  for (const [category, contracts] of Object.entries(deployedContracts)) {
    console.log(`Verifying contracts in category: ${category}`);
    for (const [name, contractData] of Object.entries(contracts)) {
      console.log(`Verifying contract: ${name} at address: ${contractData.address} ${contractData.artifactName}}`);
      await verifyOnTenderly(contractData.artifactName, contractData.address);
    }
  }
}


async function storeEnvMetadata(metadata) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.environment == undefined) metadataFile.environment = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.environment = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

async function storeVaultMetadata(address, metadata) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.vaults == undefined) metadataFile.vaults = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.vaults[address] = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

async function getVaultMetadata(address) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  return metadataFile.vaults[address];
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

async function attachContract(name, address) {
  return await ethers.getContractAt(name, address);
}

async function deployContract(name, artifactName, isVault, ...args) {
  // Check if contract is already deployed
  const existing = await getDeployedContract(artifactName || name);
  if (existing) {
    console.log(`${artifactName || name} already deployed at: ${existing.address}`);
    return existing.contract;
  }

  console.log(`Deploying ${artifactName || name}... {${args.map((v) => v.toString()).join(', ')}}}`);
  const Contract = await ethers.getContractFactory(name);
  console.log('Deploying contract', name, 'with args', args.map((v) => v.toString()).join(', '));
  const contract = await Contract.deploy(...args);
  await contract.deployed();
  console.log(`${artifactName || name} deployed to: ${contract.address}`);
  await verifyOnTenderly(name, contract.address);
  await storeContractDeployment(isVault, artifactName || name, contract.address, name, args);
  return contract;
}

async function deployProxy(name, implementationArgs, proxyArgs) {
  // Check if proxy is already deployed
  const existing = await getDeployedContract(name);
  if (existing) {
    console.log(`${name} proxy already deployed at: ${existing.address}`);
    return existing.contract;
  }

  console.log(`Deploying ${name}... {${proxyArgs.map((v) => v.toString()).join(', ')}}}`);
  const ProxyAdmin = await ethers.getContractFactory('ProxyAdmin');
  const proxyAdmin = await ProxyAdmin.deploy();
  await proxyAdmin.deployed();
  console.log(`${name}'s ProxyAdmin deployed to: ${proxyAdmin.address}`);
  await verifyOnTenderly('ProxyAdmin', proxyAdmin.address);
  await storeContractDeployment(false, `${name}ProxyAdmin`, proxyAdmin.address, 'ProxyAdmin');
  const Implementation = await ethers.getContractFactory(name);
  const implementation = await Implementation.deploy(...implementationArgs);
  await implementation.deployed();
  console.log(`${name}'s implementation deployed to: ${implementation.address}`);
  await verifyOnTenderly(name, implementation.address);
  await storeContractDeployment(false, `${name}Implementation`, implementation.address, name);
  const Proxy = await ethers.getContractFactory('TransparentUpgradeableProxy');
  // const initializeEncoded = Implementation.interface.getSighash(Implementation.interface.getFunction('initialize'));
  const initializeEncoded = Implementation.interface.encodeFunctionData('initialize', proxyArgs);
  const proxy = await Proxy.deploy(implementation.address, proxyAdmin.address, initializeEncoded);
  await proxy.deployed();
  console.log(`${name}'s proxy deployed to: ${proxy.address}`);
  await verifyOnTenderly('TransparentUpgradeableProxy', proxy.address);
  await storeContractDeployment(
    false, name, proxy.address, name, [implementation.address, proxyAdmin.address, initializeEncoded]
  );
  return (await ethers.getContractFactory(name)).attach(proxy.address);
}

async function deployPRBProxy(prbProxyRegistry) {
  const signer = await getSignerAddress();
  let proxy = (await ethers.getContractFactory('PRBProxy')).attach(await prbProxyRegistry.getProxy(signer));
  if (proxy.address == ethers.constants.AddressZero) {
    await prbProxyRegistry.deploy();
    proxy = (await ethers.getContractFactory('PRBProxy')).attach(await prbProxyRegistry.getProxy(signer));
    console.log(`PRBProxy deployed to: ${proxy.address}`);
    await verifyOnTenderly('PRBProxy', proxy.address);
    await storeContractDeployment(false, 'PRBProxy', proxy.address, 'PRBProxy');
  }
  return proxy;
}

async function deployGearboxCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING GEARBOX CORE
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy ACL contract
  const ACL = await deployContract('ACL', 'ACL', false);
  
  // Deploy AddressProviderV3 contract and set addresses
  const AddressProviderV3 = await deployContract('AddressProviderV3', 'AddressProviderV3', false, ACL.address);
  await AddressProviderV3.setAddress(toBytes32('WETH_TOKEN'), CONFIG.Core.WETH, false);

  // Deploy ContractsRegister and set its address in AddressProviderV3
  const ContractsRegister = await deployContract('ContractsRegister', 'ContractsRegister', false, AddressProviderV3.address);
  await AddressProviderV3.setAddress(toBytes32('CONTRACTS_REGISTER'), ContractsRegister.address, false);

  console.log('Gearbox Core Contracts Deployed');
  
  await verifyOnTenderly('ACL', ACL.address);
  await storeContractDeployment(false, 'ACL', ACL.address, 'ACL');
  
  await verifyOnTenderly('AddressProviderV3', AddressProviderV3.address);
  await storeContractDeployment(false, 'AddressProviderV3', AddressProviderV3.address, 'AddressProviderV3');
  
  await verifyOnTenderly('ContractsRegister', ContractsRegister.address);
  await storeContractDeployment(false, 'ContractsRegister', ContractsRegister.address, 'ContractsRegister');

  return { ACL, AddressProviderV3, ContractsRegister };
}

async function deployPools(addressProviderV3) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING POOLS
//////////////////////////////////////////////////////////////*/
  `);

  const pools = [];
  
  for (const [poolKey, poolConfig] of Object.entries(CONFIG.Pools)) {
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
      poolConfig.initialDebtCeiling || CONFIG.Core.Gearbox.initialGlobalDebtCeiling,
      poolConfig.name,
      poolConfig.symbol
    );

    console.log(`Pool ${poolKey} Deployed at ${PoolV3.address}`);
    
    await verifyOnTenderly('LinearInterestRateModelV3', LinearInterestRateModelV3.address);
    await storeContractDeployment(false, `LinearInterestRateModelV3_${poolKey}`, LinearInterestRateModelV3.address, 'LinearInterestRateModelV3');
    
    await verifyOnTenderly('PoolV3', PoolV3.address);
    await storeContractDeployment(false, `PoolV3_${poolKey}`, PoolV3.address, 'PoolV3');

    pools.push(PoolV3);
  }

  return pools;
}

async function deployGearbox() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING GEARBOX
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy LinearInterestRateModelV3 contract
  const LinearInterestRateModelV3 = await deployContract(
    'LinearInterestRateModelV3',
    'LinearInterestRateModelV3',
    false, // not a vault
    CONFIG.LinearInterestRateModelV3.U_1, // U_1
    CONFIG.LinearInterestRateModelV3.U_2, // U_2
    CONFIG.LinearInterestRateModelV3.R_base, // R_base
    CONFIG.LinearInterestRateModelV3.R_slope1, // R_slope1
    CONFIG.LinearInterestRateModelV3.R_slope2, // R_slope2
    CONFIG.LinearInterestRateModelV3.R_slope3, // R_slope3
    false // _isBorrowingMoreU2Forbidden
  );

  // Deploy ACL contract
  const ACL = await deployContract('ACL', 'ACL', false);
  const underlierAddress = CONFIG.Pools.LiquidityPool.underlier;

  // Deploy AddressProviderV3 contract and set addresses
  const AddressProviderV3 = await deployContract('AddressProviderV3', 'AddressProviderV3', false, ACL.address);
  await AddressProviderV3.setAddress(toBytes32('WETH_TOKEN'), underlierAddress, false);

  // Deploy ContractsRegister and set its address in AddressProviderV3
  const ContractsRegister = await deployContract('ContractsRegister', 'ContractsRegister', false, AddressProviderV3.address);
  await AddressProviderV3.setAddress(toBytes32('CONTRACTS_REGISTER'), ContractsRegister.address, false);

  // Deploy PoolV3 contract
  const PoolV3 = await deployContract(
    'PoolV3',
    'PoolV3',
    false, // not a vault
    CONFIG.Pools.LiquidityPool.wrappedToken, // wrapped native token
    AddressProviderV3.address, // addressProvider_
    underlierAddress, // underlyingToken_
    LinearInterestRateModelV3.address, // interestRateModel_
    CONFIG.Core.Gearbox.initialGlobalDebtCeiling, // Debt ceiling
    CONFIG.Pools.LiquidityPool.name, // name_
    CONFIG.Pools.LiquidityPool.symbol // symbol_
  );

  console.log('Gearbox Contracts Deployed');
  
  await verifyOnTenderly('LinearInterestRateModelV3', LinearInterestRateModelV3.address);
  await storeContractDeployment(false, 'LinearInterestRateModelV3', LinearInterestRateModelV3.address, 'LinearInterestRateModelV3');
  
  await verifyOnTenderly('ACL', ACL.address);
  await storeContractDeployment(false, 'ACL', ACL.address, 'ACL');
  
  await verifyOnTenderly('AddressProviderV3', AddressProviderV3.address);
  await storeContractDeployment(false, 'AddressProviderV3', AddressProviderV3.address, 'AddressProviderV3');
  
  await verifyOnTenderly('ContractsRegister', ContractsRegister.address);
  await storeContractDeployment(false, 'ContractsRegister', ContractsRegister.address, 'ContractsRegister');
  
  await verifyOnTenderly('PoolV3', PoolV3.address);
  await storeContractDeployment(false, 'PoolV3', PoolV3.address, 'PoolV3');

  return { PoolV3, AddressProviderV3 };
}

async function  deployBalancerPool() {
  // Cheat WETH to deployer
  const url = process.env.TENDERLY_FORK_URL;
  const value = BigNumber.from(10).pow(18).mul(1000);
  const signer = await getSignerAddress();
  const WETH = `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
  const reqData = {
    jsonrpc: "2.0",
    method: "tenderly_setErc20Balance",
    params: [
      WETH,
      [signer],
      value.toHexString()
    ],
    id: "1234"
  };

  try {
    const response = await axios.post(url, reqData, {
      headers: {
        'Content-Type': 'application/json'
      }
    });
    console.log('Tenderly response:', response.data);
  } catch (error) {
    console.error('Error sending POST request to Tenderly:', error);
  }

  // Approve WETH to PoolV3
  let weth = await attachContract('ERC20', WETH);
  await weth.approve(PoolV3.address, value.div(2));

  console.log("approved weth")

  await PoolV3.deposit(value.div(2), signer);

  console.log("deposited weth")

  const balancer = new BalancerSDK({
    network: Network.MAINNET,
    rpcUrl: process.env.MAINNET_RPC_URL,
  });

  const poolTokens = [WETH, PoolV3.address];
  const amountsIn = [
    value.div(2).toString(),
    value.div(2).toString(),
  ];

  await weth.approve(balancer.contracts.vault.address, value.div(2));
  await PoolV3.approve(balancer.contracts.vault.address, value.div(2));

  console.log("approved balancer pool spend")

  const weightedPoolFactory = balancer.pools.poolFactory.of(PoolType.Weighted);
  const poolParameters = {
    name: 'My-Test-Pool-Name',
    symbol: 'My-Test-Pool-Symbol',
    tokenAddresses: poolTokens,
    normalizedWeights: [
      toWad('0.5').toString(),
      toWad('0.5').toString(),
    ],
    rateProviders: [ethers.constants.AddressZero, ethers.constants.AddressZero],
    swapFeeEvm: toWad('0.01').toString(),
    owner: signer,
  };

  const { to, data } = weightedPoolFactory.create(poolParameters);
  const deployer = (await ethers.getSigners())[0]

  const receipt = await (
    await deployer.sendTransaction({
      from: signer,
      to,
      data,
    })
  ).wait();

  console.log('Pool created with receipt:', receipt);

  const { poolAddress, poolId } =
    await weightedPoolFactory.getPoolAddressAndIdWithReceipt(
      deployer.provider,
      receipt
    );

  const initJoinParams = weightedPoolFactory.buildInitJoin({
    joiner: signer,
    poolId,
    poolAddress,
    tokensIn: poolTokens,
    amountsIn: [
      toWad('500').toString(),
      toWad('500').toString(),
    ],
  });
  
  await deployer.sendTransaction({
    to: initJoinParams.to,
    data: initJoinParams.data,
  });

  console.log('Joined pool');

  const tokens = await balancer.contracts.vault.getPoolTokens(poolId);
  console.log('Pool Tokens Addresses: ' + tokens.tokens);
  console.log('Pool Tokens balances: ' + tokens.balances);

  await storeContractDeployment(false, 'lpETH-WETH-Balancer', poolAddress, 'src/reward/interfaces/balancer/IWeightedPoolFactory.sol:IWeightedPool');
}

async function deployAuraVaults() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING AURA VAULTS
//////////////////////////////////////////////////////////////*/
  `);

  const {
    MockOracle: oracle,
  } = await loadDeployedContracts();

  for (const [key, config] of Object.entries(CONFIG.Vendors.AuraVaults)) {
    const vaultName = key;
    const constructorArguments = [
      config.rewardPool,
      config.asset,
      oracle.address,
      config.auraPriceOracle,
      config.maxClaimerIncentive,
      config.maxLockerIncentive,
      config.tokenName,
      config.tokenSymbol
    ];
    await oracle.updateSpot(config.asset, config.feed.defaultPrice);
    console.log('Updated default price for', config.asset, 'to', fromWad(config.feed.defaultPrice), 'USD');

    const auraVault = await deployContract("AuraVault", vaultName, false, ...Object.values(constructorArguments));

    console.log('------------------------------------');
    console.log('Deployed ', vaultName, 'at', auraVault.address);
    console.log('------------------------------------');
    console.log('');
  }
}

async function deployVaults() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING VAULTS
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();
  const {
    PRBProxyRegistry: prbProxyRegistry,
    ...contracts
  } = await loadDeployedContracts();
  
  for (const [key, config] of Object.entries(CONFIG.Vaults)) {
    const vaultName = `CDPVault_${key}`;
    console.log('deploying vault ', vaultName);

    // Deploy oracle for the vault if defined in the config
    let oracleAddress = "";
    if (config.oracle) {
      console.log('Deploying oracle for', key);
      const oracleConfig = config.oracle.deploymentArguments;
      const deployedOracle = await deployContract(
        config.oracle.type,
        config.oracle.type,
        false,
        ...Object.values(oracleConfig)
      );
      oracleAddress = deployedOracle.address;
      console.log(`Oracle deployed for ${key} at ${oracleAddress}`);
    } else {
      console.log('No oracle defined for', key);
      return;
    }

    var token;
    var tokenAddress = config.token;
    let tokenScale = config.tokenScale;
    let tokenSymbol = config.tokenSymbol;

    // initialize the token
    if (tokenAddress == undefined || tokenAddress == null) {
      console.log('Deploying token for', key);
      token = await deployContract(
        'ERC20PresetMinterPauser',
        'MockCollateralToken',
        false, // not a vault
        "MockCollateralToken", // name
        "MCT" // symbol
      );
      tokenAddress = token.address;
      tokenScale = new ethers.BigNumber.from(10).pow(await token.decimals());
      tokenSymbol = "MCT";
    }

    const poolAddress = config.poolAddress;
    if (poolAddress == undefined || poolAddress == null) {
      console.log('No pool address defined for', key);
      return;
    }
    console.log('poolAddress', poolAddress);
    
    const cdpVault = await deployContract(
      config.type,
      vaultName,
      true,
      [
        poolAddress,
        oracleAddress,
        tokenAddress,
        tokenScale
      ],
      [...Object.values(config.deploymentArguments.configs).map((v) => v === "deployer" ? signer : v)]
    );

    console.log('CDPVault deployed for', vaultName, 'at', cdpVault.address);

    console.log('Set debtCeiling to', fromWad(config.deploymentArguments.debtCeiling), 'for', vaultName);
    const pool = await attachContract('PoolV3', poolAddress);
    await pool.setCreditManagerDebtLimit(cdpVault.address, config.deploymentArguments.debtCeiling);
    // await cdm["setParameter(address,bytes32,uint256)"](cdpVault.address, toBytes32("debtCeiling"), config.deploymentArguments.debtCeiling);
    
    console.log('------------------------------------');

    console.log('Initialized', vaultName, 'with a debt ceiling of', fromWad(config.deploymentArguments.debtCeiling), 'Credit');

    // deploy reward manager
    
    const rewardManager = await deployContract(
      "src/spectra-rewards/RewardManagerSpectra.sol:RewardManagerSpectra",
      "RewardManagerSpectra",
      false, 
      cdpVault.address,
      tokenAddress,
      prbProxyRegistry.address,
      signer,
      "0x335d354e8551086F780285FF886216af3f8aca9a"
    );

    console.log('Deployed RewardManager for', vaultName, 'at', rewardManager.address);

    await cdpVault["setParameter(bytes32,address)"](toBytes32("rewardManager"), rewardManager.address);
    console.log('Set reward manager for', vaultName, 'to', rewardManager.address);

    // if (config.oracle)
    // await oracle.updateSpot(tokenAddress, config.oracle.defaultPrice);
    // console.log('Updated default price for', key, 'to', fromWad(config.oracle.defaultPrice), 'USD');

    await storeVaultMetadata(
      cdpVault.address,
      {
        contractName: vaultName,
        name: config.name,
        description: config.description,
        artifactName: 'CDPVault',
        pool: pool.address,
        oracle: oracleAddress,
        token: tokenAddress,
        tokenScale: tokenScale,
        quotas: config.quotas
      }
    );

    console.log('------------------------------------');
    console.log('');
  }
}

/*//////////////////////////////////////////////////////////////
                        DEPLOYING REWARD CONTRACTS
//////////////////////////////////////////////////////////////*/

async function deployLoopToken(radiantDeployHelper, amountInETH) {
  console.log('Deploying LoopToken...');
  const tx = await radiantDeployHelper.deployLoopToken(toWad(amountInETH));
  const receipt = await tx.wait();

  const event = receipt.events?.find(e => e.event === "LoopTokenDeployed");

  if (event) {
    const loopTokenAddress = event.args.tokenAddress;
    console.log(`LoopToken deployed to: ${loopTokenAddress}`);
    await storeContractDeployment(false, 'LoopToken', loopTokenAddress, 'ERC20Mock', []);

    return loopTokenAddress;
  } else {
    console.error("TokenDeployed event not found");
    return null;
  }
}

async function deployPriceProvider(radiantDeployHelper) {
  console.log('Deploying PriceProvider...');
  const tx = await radiantDeployHelper.deployPriceProvider();
  const receipt = await tx.wait();

  const event = receipt.events?.find(e => e.event === "PriceProviderDeployed");

  if (event) {
    const priceProviderAddress = event.args.priceProviderAddress;
    console.log(`PriceProvider deployed to: ${priceProviderAddress}`);
    await storeContractDeployment(false, 'PriceProvider', priceProviderAddress, 'MockPriceProvider', []);
    return priceProviderAddress;
  } else {
    console.log("PriceProviderDeployed event not found");
    return null;
  }
}

async function deployWeighedPool(radiantDeployHelper, amountInETH) {
  console.log('Wrapping ETH...');
  const wrapTx = await radiantDeployHelper.wrapETH(toWad(amountInETH));
  await wrapTx.wait();

  console.log('Deploying WeightedPool...');
  const tx = await radiantDeployHelper.createWeightedPool();
  const receipt = await tx.wait();

  // Find the event with the name "WeightedPoolDeployed"
  const event = receipt.events?.find(e => e.event === "WeightedPoolDeployed");

  if (event) {
    const weightedPoolAddress = event.args.poolAddress;
    await storeContractDeployment(false, 'BalancerPool-WETH-LOOP', weightedPoolAddress, 'IVault', []);
    console.log(`WeightedPool deployed to: ${weightedPoolAddress}`);
    return weightedPoolAddress;
  } else {
    console.log("WeightedPoolDeployed event not found");
    return null;
  }
}

async function deployRadiantDeployHelper() {
  
  console.log('Deploying RadiantDeployHelper...');

  // Use the deployContract function to deploy the RadiantDeployHelper contract
  const radiantDeployHelper = await deployContract('RadiantDeployHelper', 'RadiantDeployHelper');
  console.log(`RadiantDeployHelper deployed to: ${radiantDeployHelper.address}`);

  // Send ETH to the deployed contract using the signer object
  const deployer = (await ethers.getSigners())[0]
  console.log(`Sending ETH to ${radiantDeployHelper.address} from ${deployer.address}...`);
  const tx = await deployer.sendTransaction({
    to: radiantDeployHelper.address,
    value:  ethers.utils.parseEther("5000000")
  });
  await tx.wait();

  const loopToken = await deployLoopToken(radiantDeployHelper, '5000000');
  const priceProvider = await deployPriceProvider(radiantDeployHelper);
  const lpTokenAddress = await deployWeighedPool(radiantDeployHelper, '5000000');

  console.log(`LoopToken deployed to: ${loopToken}`);
  console.log(`PriceProvider deployed to: ${priceProvider}`);
  console.log(`WeightedPool deployed to: ${lpTokenAddress}`);
  
  return [radiantDeployHelper.address, loopToken, priceProvider, lpTokenAddress];
}

async function setupMultiFeeDistribution(multiFeeDistribution, incentivesController, treasury, lpTokenAddress) {
  console.log(`Setting up MultiFeeDistribution for ${multiFeeDistribution.address} with IncentivesController at ${incentivesController.address}, treasury at ${treasury}, and LP token at ${lpTokenAddress}...`);

  // Define lock durations and reward multipliers
  const lockDurations = [2592000, 7776000, 15552000, 31104000]; // in seconds
  const rewardMultipliers = [1, 4, 10, 25]; // multipliers

  // Set lock type info
  await multiFeeDistribution.setLockTypeInfo(lockDurations, rewardMultipliers);
  console.log('Set lock type info.');

  // Set addresses
  await multiFeeDistribution.setAddresses(incentivesController.address, treasury);
  console.log('Set addresses for MultiFeeDistribution.');

  // Set LP Token address
  await multiFeeDistribution.setLPToken(lpTokenAddress);
  console.log('Set LP token address.');

  // Set minters
  const minters = [incentivesController.address];
  await multiFeeDistribution.setMinters(minters);
  console.log('Set minters for MultiFeeDistribution.');
}

async function registerRewards(loopTokenAddress, incentivesController, rewardAmount) {
  const signer = await getSignerAddress();
  console.log('Registering rewards...');
  
  let loopToken = await attachContract('ERC20Mock', loopTokenAddress);

  // Mint rewardAmount of loopToken to the deployer's address
  await loopToken.mint(signer, rewardAmount);
  console.log(`Minted ${ethers.utils.formatEther(rewardAmount)} LOOP tokens to deployer.`);

  // Approve the incentivesController to spend the tokens
  await loopToken.approve(incentivesController.address, rewardAmount);
  console.log('Approved incentivesController to spend LOOP tokens.');

  // Transfer the minted loopToken to the incentivesController
  await loopToken.transfer(incentivesController.address, rewardAmount);
  console.log(`Transferred ${ethers.utils.formatEther(rewardAmount)} LOOP tokens to incentivesController.`);

  // Register the reward deposit in the incentivesController
  await incentivesController.registerRewardDeposit(rewardAmount);
  console.log('Registered reward deposit in incentivesController.');
}


async function registerVaults() {
  const { VaultRegistry: vaultRegistry } = await loadDeployedContracts()
  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    console.log(`${name}: ${vault.address}`);
    await vaultRegistry.addVault(vault.address);

    console.log('Added', name, 'to vault registry');
  }
}

async function deployRadiant() {
  console.log('Deploying Radiant Contracts...');
  const signer = await getSignerAddress();

  const {
    Treasury: treasury,
  } = await loadDeployedContracts();
  
  // Deploy the RadiantDeployHelper contract and get the addresses of the LoopToken, PriceProvider, and LP Token
  [
    deployHelper,
    loopToken,
    priceProvider,
    lpTokenAddress
  ] = await deployRadiantDeployHelper();

  
  const multiFeeDistribution = await deployProxy('MultiFeeDistribution', [], [
    loopToken,
    CONFIG.Tokenomics.MultiFeeDistribution.lockZap,
    CONFIG.Tokenomics.MultiFeeDistribution.dao,
    priceProvider,
    CONFIG.Tokenomics.MultiFeeDistribution.rewardsDuration,
    CONFIG.Tokenomics.MultiFeeDistribution.rewardsLookback,
    CONFIG.Tokenomics.MultiFeeDistribution.lockDuration,
    CONFIG.Tokenomics.MultiFeeDistribution.burnRatio,
    CONFIG.Tokenomics.MultiFeeDistribution.vestDuration
  ]);

  const eligibilityDataProvider = await deployProxy('EligibilityDataProvider', [], [
    vaultRegistry.address,
    multiFeeDistribution.address,
    priceProvider
  ]);

  const incentivesController = await deployProxy('ChefIncentivesController', [], [
    signer,
    eligibilityDataProvider.address,
    multiFeeDistribution.address,
    CONFIG.Tokenomics.IncentivesController.rewardsPerSecond,
    loopToken,
    CONFIG.Tokenomics.IncentivesController.endingTimeCadence
  ]);

  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    console.log(`${name}: ${vault.address}`);
    await incentivesController.addPool(vault.address, '100');
    console.log('Added', name, 'to incentives controller');
    await vault["setParameter(bytes32,address)"](toBytes32("rewardController"), incentivesController.address);
    console.log(`Set incentives controller for ${name}`);
    await vaultRegistry.addVault(vault.address);
    console.log('Added', name, 'to vault registry');
  }
  
  await eligibilityDataProvider.setChefIncentivesController(incentivesController.address);
  console.log('Set incentives controller for eligibility data provider');

  await setupMultiFeeDistribution(multiFeeDistribution, incentivesController, treasury.address, lpTokenAddress);

  await registerRewards(loopToken, incentivesController, CONFIG.Tokenomics.IncentivesController.rewardAmount);

  await incentivesController.start();

  console.log('Radiant Contracts Deployed');
}

async function logVaults() {
  const { CDM: cdm } = await loadDeployedContracts()
  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    console.log(`${name}: ${vault.address}`);
    console.log('  debtCeiling:', fromWad(await cdm.creditLine(vault.address)));
    const vaultConfig = await vault.vaultConfig();
    console.log('  debtFloor:', fromWad(vaultConfig.debtFloor));
    console.log('  liquidationRatio:', fromWad(vaultConfig.liquidationRatio));
    const liquidationConfig = await vault.liquidationConfig();
    console.log('  liquidationPenalty:', fromWad(liquidationConfig.liquidationPenalty));
    console.log('  liquidationDiscount:', fromWad(liquidationConfig.liquidationDiscount));
  }
}

async function createPositions() {
  const { CDM: cdm, PositionAction20: positionAction, PRBProxyRegistry: proxyRegistry } = await loadDeployedContracts();
  const prbProxyRegistry = await attachContract('PRBProxyRegistry', proxyRegistry.address);

  const signer = await getSignerAddress();
  const proxy = await deployPRBProxy(prbProxyRegistry);

  // anvil or tenderly
  try {
    const ethPot = await ethers.getImpersonatedSigner('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2');
    await ethPot.sendTransaction({ to: signer, value: toWad('10') });
  } catch {
    const ethPot = (new ethers.providers.JsonRpcProvider(process.env.TENDERLY_FORK_URL)).getSigner('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2');
    await ethPot.sendTransaction({ to: signer, value: toWad('10') });
  }
  console.log('Sent 10 ETH to', signer);

  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    let token = await attachContract('ERC20PresetMinterPauser', await vault.token());
    const config = Object.values(CONFIG.Vaults).find((v) => v.token.toLowerCase() == token.address.toLowerCase());
    console.log(`${name}: ${vault.address}`);

    const amountInWad = config.deploymentArguments.configs.debtFloor.mul('5').add(toWad('1'));
    const amount = amountInWad.mul(await vault.tokenScale()).div(toWad('1'));
    await token.approve(proxy.address, amount);

    // anvil or tenderly
    try {
      token = token.connect(await ethers.getImpersonatedSigner(config.tokenPot));
      await token.transfer(signer, amount);
    } catch {
      token = token.connect((new ethers.providers.JsonRpcProvider(process.env.TENDERLY_FORK_URL)).getSigner(config.tokenPot));
      await token.transfer(signer, amount);
    }
    console.log('Sent', fromWad(amountInWad), await token.symbol(), 'signer');

    await proxy.execute(
      positionAction.address,
      positionAction.interface.encodeFunctionData(
        'depositAndBorrow',
        [
          proxy.address,
          vault.address,
          [token.address, amount, signer, [0, 0, ethers.constants.AddressZero, 0, 0, ethers.constants.AddressZero, 0, ethers.constants.HashZero]],
          [config.deploymentArguments.configs.debtFloor, signer, [0, 0, ethers.constants.AddressZero, 0, 0, ethers.constants.AddressZero, 0, ethers.constants.HashZero]],
          [0, 0, 0, 0, 0, ethers.constants.HashZero, ethers.constants.HashZero]
      ]
      ),
      { gasLimit: 2000000 }
    );
    
    const position = await vault.positions(proxy.address);
    console.log('Borrowed', fromWad(position.normalDebt), 'Credit against', fromWad(position.collateral), await token.symbol());
  }
}

async function isContractDeployed(name) {
  const deploymentFilePath = await getDeploymentFilePath();
  if (!fs.existsSync(deploymentFilePath)) return false;
  
  const deployment = JSON.parse(fs.readFileSync(deploymentFilePath));
  
  // Check in both core and vaults
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

async function deployCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING CORE
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();

  if (hre.network.name == 'tenderly') {
    await ethers.provider.send('tenderly_setBalance', [[signer], ethers.utils.hexValue(toWad('100').toHexString())]);
  }

  const { AddressProviderV3: addressProviderV3 } = await deployGearboxCore();
  const pools = await deployPools(addressProviderV3);
  
  // Use the first pool as the main pool for remaining setup
  const pool = pools[0];

  console.log('PoolV3 deployed to:', pool.address);
  console.log('AddressProviderV3 deployed to:', addressProviderV3.address);

  const { stakingLpEth, lockLpEth } = await deployStakingAndLockingLP(pool);

  const treasuryReplaceParams = {
    'deployer': signer,
    'stakingLpEth': stakingLpEth.address
  };

  const { payees, shares, admin } = replaceParams(CONFIG.Core.Treasury.constructorArguments, treasuryReplaceParams);
  const treasury = await deployContract('Treasury', 'Treasury', false, payees, shares, admin);
  console.log('Treasury deployed to:', treasury.address);
  
  await addressProviderV3.setAddress(toBytes32('TREASURY'), treasury.address, false);
  await pool.setTreasury(treasury.address);

  // Deploy Vault Registry
  const vaultRegistry = await deployContract('VaultRegistry');
  console.log('Vault Registry deployed to:', vaultRegistry.address);

  // Deploy actions with the vault registry
  const { flashlender, proxyRegistry } = await deployActions(pool, vaultRegistry);
  
  console.log('------------------------------------');
}

async function deployStakingAndLockingLP(pool) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                  DEPLOYING STAKING & LOCKING LP
//////////////////////////////////////////////////////////////*/
  `);

  const stakingLpEth = await deployContract(
    'StakingLPEth', 
    'StakingLPEth', 
    false, 
    pool.address, 
    "StakingLPEth", 
    "slpETH"
  );
  console.log('StakingLPEth deployed to:', stakingLpEth.address);

  const lockLpEth = await deployContract(
    'StakingLPEth', 
    'LockingLPEth', 
    false, 
    pool.address, 
    "LockLPEth", 
    "llpETH"
  );
  console.log('LockLPEth deployed to:', lockLpEth.address);

  await verifyOnTenderly('StakingLPEth', stakingLpEth.address);
  await storeContractDeployment(false, 'StakingLPEth', stakingLpEth.address, 'StakingLPEth');

  await verifyOnTenderly('LockingLPEth', lockLpEth.address);
  await storeContractDeployment(false, 'LockingLPEth', lockLpEth.address, 'StakingLPEth');

  return { stakingLpEth, lockLpEth };
}

async function deployActions(pool, vaultRegistry) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                      DEPLOYING ACTIONS
//////////////////////////////////////////////////////////////*/
  `);

  // Deploy Flashlender
  const flashlender = await deployContract('Flashlender', 'Flashlender', false, pool.address, CONFIG.Core.Flashlender.constructorArguments.protocolFee_);
  
  const UINT256_MAX = ethers.constants.MaxUint256;
  await pool.setCreditManagerDebtLimit(flashlender.address, UINT256_MAX);
  console.log('Set credit manager debt limit for flashlender to max');
  
  // Deploy PRBProxyRegistry
  const proxyRegistry = await deployContract('PRBProxyRegistry');
  console.log('PRBProxyRegistry deployed to ', proxyRegistry.address);
  
  // Deploy Actions
  const swapAction = await deployContract(
   'SwapAction', 'SwapAction', false, ...Object.values(CONFIG.Core.Actions.SwapAction.constructorArguments)
  );
  const poolAction = await deployContract(
   'PoolAction', 'PoolAction', false, ...Object.values(CONFIG.Core.Actions.PoolAction.constructorArguments)
  );

  // Deploy ERC165Plugin and Position Actions
  await deployContract('ERC165Plugin');
  await deployContract('PositionAction20', 'PositionAction20', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  await deployContract('PositionAction4626', 'PositionAction4626', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  await deployContract('PositionActionPendle', 'PositionActionPendle', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  await deployContract('PositionActionTranchess', 'PositionActionTranchess', false, flashlender.address, swapAction.address, poolAction.address, vaultRegistry.address, CONFIG.Core.WETH);
  
  console.log('------------------------------------');

  return { flashlender, proxyRegistry, swapAction, poolAction };
}

async function deployGauge(poolAddress) {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING GAUGE
//////////////////////////////////////////////////////////////*/
  `);

  if (poolAddress == undefined || poolAddress == null) {
    console.log('No pool address defined for gauge');
    return;
  }

  const liquidityPool = await attachContract('PoolV3', poolAddress);
  const latestBlock = await ethers.provider.getBlock('latest');
  const blockTimestamp = latestBlock.timestamp;
  const firstEpochTimestamp = blockTimestamp + 300; // Start 5 minutes from now
  
  const voter = await deployContract('LoopVoter', 'LoopVoter', false, addressProviderV3.address, firstEpochTimestamp);
  console.log(`Voter deployed to: ${voter.address}`);

  // Deploy GaugeV3 contract
  const gaugeV3 = await deployContract('GaugeV3', 'GaugeV3', false, liquidityPool.address, voter.address);
  console.log(`GaugeV3 deployed to: ${gaugeV3.address}`);
  
  // Assuming quotaKeeper and other necessary contracts are already deployed and their addresses are known
  const poolQuotaKeeperV3 = await deployContract('PoolQuotaKeeperV3', 'PoolQuotaKeeperV3', false, liquidityPool.address);
  await liquidityPool.setPoolQuotaKeeper(poolQuotaKeeperV3.address);

  // Set Gauge in QuotaKeeper
  await poolQuotaKeeperV3.setGauge(gaugeV3.address);
  console.log('Set gauge in QuotaKeeper');

  const { VaultRegistry: vaultRegistry } = await loadDeployedContracts()
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

    const tokenAddress = await vault.token();
    await poolQuotaKeeperV3.setCreditManager(tokenAddress, vault.address);
    console.log('Set Credit Manager in QuotaKeeper for token:', tokenAddress);
    
    const minRate = vaultMetadata.quotas.minRate;
    const maxRate = vaultMetadata.quotas.maxRate;
    
    console.log('Setting quota rates for token:', tokenAddress, 'minRate:', minRate, 'maxRate:', maxRate);
    await gaugeV3.addQuotaToken(tokenAddress, minRate, maxRate);

    console.log('Added quota token to GaugeV3 for token:', tokenAddress);
  }

  // Unfreeze the epoch in Gauge
  await gaugeV3.setFrozenEpoch(false);
  console.log('Set frozen epoch to false in GaugeV3');

  //await quotaKeeper.updateRates();
  
  console.log('Gauge and related configurations have been set.');
}

((async () => {
  await deployCore();
  // await deployAuraVaults();
  await deployVaults();
  await registerVaults();
  // await deployGauge();
  // await deployRadiant();
  // await deployGearbox();
  // await logVaults();
  // await createPositions();
  // await verifyAllDeployedContracts();
})()).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
