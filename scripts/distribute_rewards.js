// Script to distribute BNB rewards based on user collateral in the CDP vault
require('dotenv').config();
const { ethers } = require('hardhat');
const fs = require('fs');

// CDP Vault contract address
const CDP_VAULT_ADDRESS = '0x03C07e6d561b664246058974dB31dbF1c1C0B416';

const PROXY_REGISTRY_ADDRESS = '0xD83B0a990ac3dBc9A5F3862b84883Da78F286283';

// ABI for the ModifyPosition event
const CDP_VAULT_ABI = [
  'function positions(address) view returns (uint256 collateral, uint256 debt, uint256 lastDebtUpdate, uint256 cumulativeIndexLastUpdate, uint192 cumulativeQuotaIndexLU, uint128 cumulativeQuotaInterest)',
  'event ModifyPosition(address indexed position, uint256 debt, uint256 collateral, uint256 totalDebt)'
];

// Add the PRB Proxy Registry ABI
const PROXY_REGISTRY_ABI = [
  'function isProxy(address) view returns (bool)',
];

const PRB_PROXY_ABI = [
  'function owner() view returns (address)',
];

// Add at the top of the script with other constants
const EXECUTED_TRANSACTIONS = [
    // First batch
    '0xaeAE6a6Ed740E597E0320928396aE35A163b5628',  // Confirmed in block 47405779
    '0x5786C96F80ad6a00de474b85Bb83dc537d8aA088',  // Confirmed in block 47405780
    '0x793EDb925eCe66604ebC0673c2D2fa5dBC497D61',  // Confirmed in block 47405781
    '0xC4e0B2C2C766b1140AE40381D56D52604d6FBd4F',  // Confirmed in block 47405782
    '0x2b28fE276e97F4467c0D7004162BB1812eCbF1CF',  // Confirmed in block 47405785
    // Second batch
    '0x44ceb39802d6BBBB4b37E70c11A8779A2F89F48d',  // Confirmed in block 47406100
    '0xBb9800B12BE718c5D1d47587329B1114375Efe26',  // Confirmed in block 47406102
    '0x07e2024abC1D20606F9a78Ef9ed34Cf9f5221222',  // Confirmed in block 47406105
    '0x637b935CbA030Aeb876eae07Aa7FF637166de4D6',  // Confirmed in block 47406107
    '0xc938b31aBc64c6a9479Aeb6864D27c27e0Fa90Ae',  // Confirmed in block 47406109
].map(addr => addr.toLowerCase());

async function main() {
  // Parse command line arguments
  const shouldSend = process.env.SEND === 'true';
  console.log(`Mode: ${shouldSend ? 'SENDING transactions' : 'SIMULATING transactions'}`);
  
  // Connect to the BNB Chain
  const [deployer] = await ethers.getSigners();
  console.log(`Account: ${deployer.address}`);
  
  // Get the balance of BNB to distribute - convert string to BigNumber
  const balance = ethers.BigNumber.from("4590000000000000000");
  const amountToDistribute = balance; // 100% of the balance
  console.log(`Balance: ${ethers.utils.formatEther(balance)} BNB`);
  console.log(`Amount to distribute: ${ethers.utils.formatEther(amountToDistribute)} BNB`);
  
  // Connect to the CDP Vault contract with full ABI to access positions()
  const cdpVault = new ethers.Contract(CDP_VAULT_ADDRESS, CDP_VAULT_ABI, deployer);
  
  // Get the block number to start searching for events - we only need this to get the list of position owners
  const latestBlock = await ethers.provider.getBlockNumber();
  const fromBlock = 46454092;
  
  console.log(`Searching for ModifyPosition events from block ${fromBlock} to ${latestBlock} to get position owners`);
  
  // Query for ModifyPosition events just to get the list of unique position owners
  const events = await cdpVault.queryFilter(cdpVault.filters.ModifyPosition(), fromBlock, latestBlock);
  console.log(`Found ${events.length} ModifyPosition events`);
  
  // Get unique position owners
  const uniquePositionOwners = [...new Set(events.map(event => event.args.position))];
  console.log(`Found ${uniquePositionOwners.length} unique position owners`);
  
  // Query current collateral balances directly from the vault
  const userCollateral = {};
  for (const owner of uniquePositionOwners) {
    const position = await cdpVault.positions(owner);
    const collateral = position.collateral; // First value in the returned tuple
    if (!collateral.isZero()) {
      userCollateral[owner] = collateral;
    }
  }
  
  // Filter out users with zero collateral
  const activeUsers = Object.entries(userCollateral);
  
  if (activeUsers.length === 0) {
    console.log('No active users with collateral found');
    return;
  }
  
  console.log(`Found ${activeUsers.length} active users with collateral`);
  
  // Calculate total collateral
  const totalCollateral = activeUsers.reduce(
    (sum, [_, collateral]) => sum.add(collateral),
    ethers.BigNumber.from(0)
  );
  
  console.log(`Total collateral: ${ethers.utils.formatEther(totalCollateral)}`);
  
  // Connect to the Proxy Registry contract
  const proxyRegistry = new ethers.Contract(PROXY_REGISTRY_ADDRESS, PROXY_REGISTRY_ABI, deployer);
  
  // Calculate rewards for each user
  const rewards = {};
  let totalRewardsToSend = ethers.BigNumber.from(0);
  
  // Estimate total gas cost
  let totalGasEstimate = ethers.BigNumber.from(0);
  const gasPrice = await ethers.provider.getGasPrice();
  console.log(`Current gas price: ${ethers.utils.formatUnits(gasPrice, 'gwei')} gwei`);
  
  // Create a mapping to track actual recipients (proxy owner or original address)
  const actualRecipients = {};
  
  // First, determine the actual recipients for each position
  for (const [address, collateral] of activeUsers) {
    let recipient;
    try {
      if (await proxyRegistry.isProxy(address)) {
        const proxyContract = new ethers.Contract(address, PRB_PROXY_ABI, deployer);
        recipient = await proxyContract.owner();
        console.log(`Position ${address} is a proxy, owner is ${recipient}`);
      } else {
        recipient = address;
        console.log(`Position ${address} is not a proxy`);
      }
      actualRecipients[address] = recipient;
    } catch (error) {
      console.warn(`Warning: Could not check proxy status for ${address}: ${error.message}`);
      actualRecipients[address] = address; // fallback to original address
    }
  }
  
  // Now calculate rewards and aggregate them by actual recipient
  const aggregatedRewards = {};
  
  for (const [address, collateral] of activeUsers) {
    const recipient = actualRecipients[address];
    
    // Calculate reward proportional to user's collateral
    const userShare = collateral.mul(ethers.constants.WeiPerEther).div(totalCollateral);
    const reward = amountToDistribute.mul(userShare).div(ethers.constants.WeiPerEther);
    
    // Aggregate rewards by recipient
    if (aggregatedRewards[recipient]) {
      aggregatedRewards[recipient] = aggregatedRewards[recipient].add(reward);
    } else {
      aggregatedRewards[recipient] = reward;
    }
    
    // Store original calculation for logging
    rewards[address] = reward;
    totalRewardsToSend = totalRewardsToSend.add(reward);
    
    console.log(
      `Position ${address} (recipient ${recipient}): ${ethers.utils.formatEther(collateral)} collateral, ` +
      `${ethers.utils.formatEther(reward)} BNB reward`
    );
  }
  
  // Estimate gas costs for the aggregated transfers
  for (const [recipient, reward] of Object.entries(aggregatedRewards)) {
    try {
      const gasEstimate = await deployer.estimateGas({
        to: recipient,
        value: reward,
      });
      totalGasEstimate = totalGasEstimate.add(gasEstimate);
      
      console.log(
        `Recipient ${recipient}: ${ethers.utils.formatEther(reward)} BNB total reward, ` +
        `Est. gas: ${gasEstimate.toString()}`
      );
    } catch (error) {
      console.warn(`Warning: Could not estimate gas for ${recipient}: ${error.message}`);
    }
  }
  
  const totalGasCost = totalGasEstimate.mul(gasPrice);
  console.log(`\nDistribution Summary:`);
  console.log(`Total rewards to send: ${ethers.utils.formatEther(totalRewardsToSend)} BNB`);
  console.log(`Estimated total gas cost: ${ethers.utils.formatEther(totalGasCost)} BNB`);
  console.log(`Number of transactions: ${activeUsers.length}`);
  console.log(`Average gas per tx: ${totalGasEstimate.div(activeUsers.length).toString()}`);
  
  if (shouldSend) {
    console.log('\nSending transactions...');
    
    const delay = (ms) => new Promise(resolve => setTimeout(resolve, ms));
    
    // Use aggregatedRewards for sending transactions
    for (const [recipient, reward] of Object.entries(aggregatedRewards)) {
      // Check if this transaction was already executed
      if (EXECUTED_TRANSACTIONS.includes(recipient.toLowerCase())) {
        console.log(`Skipping already processed recipient ${recipient}`);
        continue;
      }
      
      // Skip very small amounts to avoid dust
      if (reward.lt(ethers.utils.parseEther('0.0001'))) {
        console.log(`Skipping dust amount for ${recipient}: ${ethers.utils.formatEther(reward)} BNB`);
        continue;
      }
      
      try {
        console.log(`\nSending ${ethers.utils.formatEther(reward)} BNB to ${recipient}`);
        
        // Send the reward
        const tx = await deployer.sendTransaction({
          to: recipient,
          value: reward,
        });
        
        console.log(`Transaction sent: ${tx.hash}`);
        
        // Wait for transaction confirmation
        console.log('Waiting for confirmation...');
        const receipt = await tx.wait();
        console.log(`Transaction confirmed in block ${receipt.blockNumber}`);
        
        // Increase delay to 5 seconds between transactions
        console.log('Waiting 3 seconds before next transaction...');
        await delay(3000);
        
      } catch (error) {
        console.error(`Error sending transaction to ${recipient}:`, error.message);
        if (error.message.includes('nonce')) {
          console.log('Nonce error detected. Stopping distribution to prevent chain issues.');
          break;
        }
      }
    }
    
    console.log('\nReward distribution completed');
  } else {
    console.log('\nSimulation completed. Run with --send flag to actually send transactions.');
  }
  
  // Update the distribution data to include both position and recipient information
  const distributionData = {
    timestamp: new Date().toISOString(),
    distributor: deployer.address,
    totalDistributed: ethers.utils.formatEther(totalRewardsToSend),
    estimatedGasCost: ethers.utils.formatEther(totalGasCost),
    mode: shouldSend ? 'sent' : 'simulated',
    positionRewards: Object.fromEntries(
      Object.entries(rewards).map(([address, amount]) => [
        address,
        {
          recipient: actualRecipients[address],
          amount: ethers.utils.formatEther(amount)
        }
      ])
    ),
    recipientTotals: Object.fromEntries(
      Object.entries(aggregatedRewards).map(([recipient, amount]) => [
        recipient,
        ethers.utils.formatEther(amount)
      ])
    )
  };
  
  const filename = `reward-distribution-${new Date().toISOString().replace(/:/g, '-')}.json`;
  fs.writeFileSync(filename, JSON.stringify(distributionData, null, 2));
  
  console.log(`Distribution data saved to ${filename}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
