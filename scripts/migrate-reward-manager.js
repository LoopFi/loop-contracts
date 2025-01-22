const { ethers } = require("hardhat");

async function main() {
  const vaultAddress = "0x9BfCD3788f923186705259ae70A1192F601BeB47";
  const rewardManagerAddress = "0xCaf5e9cB6F005ed95F0a00edAdd16593467eE852";
  
  // Create contract instances
  const vault = await ethers.getContractAt("CDPVaultSpectra", vaultAddress);
  const rewardManager = await ethers.getContractAt("RewardManagerSpectra", rewardManagerAddress);

  // Get current block
  const currentBlock = await ethers.provider.getBlockNumber();
  
  // Define filter for ModifyCollateralAndDebt events
  const filter = vault.filters.ModifyCollateralAndDebt();

  // Fetch all events
  const events = await vault.queryFilter(filter, 0, currentBlock);

  console.log(`Found ${events.length} ModifyCollateralAndDebt events`);

  // Process each event
  const positions = new Set();
  const positionData = {};
  const rewardStates = {};
  const userRewards = {};

  for (const event of events) {
    const { position } = event.args;
    positions.add(position);
  }

  console.log(`Found ${positions.size} unique positions`);

  // Fetch reward tokens
  const rewardTokensLength = await rewardManager.rewardTokensLength();
  const rewardTokens = [];
  
  for (let i = 0; i < rewardTokensLength; i++) {
    const token = await rewardManager.rewardTokens(i);
    rewardTokens.push(token);
  }

  console.log(`Found ${rewardTokens.length} reward tokens`);

  // Fetch reward states and user rewards for each position
  for (const position of positions) {
    rewardStates[position] = {};
    userRewards[position] = {};

    // Get reward state for each token
    for (const token of rewardTokens) {
      const rewardState = await rewardManager.rewardState(token);
      rewardStates[position][token] = {
        index: rewardState.index.toString(),
        lastBalance: rewardState.lastBalance.toString()
      };

      // Get user reward for each token
      const userReward = await rewardManager.userReward(token, position);
      userRewards[position][token] = {
        index: userReward.index.toString(),
        accrued: userReward.accrued.toString()
      };
    }
  }

  // Output results
  console.log('\nReward States and User Rewards by Position:');
  for (const position of positions) {
    console.log(`\nPosition: ${position}`);
    console.log('Reward States:');
    for (const token of rewardTokens) {
      console.log(`  Token ${token}:`);
      console.log(`    Index: ${rewardStates[position][token].index}`);
      console.log(`    Last Balance: ${rewardStates[position][token].lastBalance}`);
    }
    
    console.log('User Rewards:');
    for (const token of rewardTokens) {
      console.log(`  Token ${token}:`);
      console.log(`    Index: ${userRewards[position][token].index}`);
      console.log(`    Accrued: ${userRewards[position][token].accrued}`);
    }
  }

  // Save data to file with network name
  const fs = require('fs');
  const network = hre.network.name;
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `reward-manager-migration-${network}-${timestamp}.json`;
  
  const data = {
    network,
    timestamp,
    blockNumber: currentBlock,
    positions: Array.from(positions),
    rewardTokens,
    rewardStates,
    userRewards
  };

  fs.writeFileSync(filename, JSON.stringify(data, null, 2));
  console.log(`\nData saved to ${filename}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
