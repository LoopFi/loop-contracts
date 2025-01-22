const { ethers } = require("hardhat");
const fs = require('fs');

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

  // Process each event to get unique positions
  const positions = new Set();
  for (const event of events) {
    const { position } = event.args;
    positions.add(position);
  }

  console.log(`Found ${positions.size} unique positions`);

  // Fetch reward tokens
  const rewardTokensLength = await rewardManager.rewardTokensLength();
  const rewardTokens = [];
  const rewardStates = {};
  
  // Get reward tokens and their states
  for (let i = 0; i < rewardTokensLength; i++) {
    const token = await rewardManager.rewardTokens(i);
    rewardTokens.push(token);
    
    // Get reward state for each token
    const state = await rewardManager.rewardState(token);
    rewardStates[token] = {
      index: state.index.toString(),
      lastBalance: state.lastBalance.toString()
    };
  }

  console.log(`Found ${rewardTokens.length} reward tokens`);
  console.log('Reward States:', rewardStates);

  // Get user rewards for each token and position
  const userRewards = {};
  for (const token of rewardTokens) {
    userRewards[token] = {};
    for (const position of positions) {
      const reward = await rewardManager.userReward(token, position);
      userRewards[token][position] = {
        index: reward.index.toString(),
        accrued: reward.accrued.toString()
      };
    }
  }

  // Save data to file with new structure
  const network = hre.network.name;
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const data = {
    network,
    timestamp,
    blockNumber: currentBlock,
    positions: Array.from(positions),
    rewardTokens,
    rewardStates,
    userRewards  // Now structured as token -> user -> reward
  };

  const filename = `reward-manager-migration-${network}.json`;
  fs.writeFileSync(filename, JSON.stringify(data, null, 2));
  console.log(`\nData saved to ${filename}`);

  await migrateRewardManager();
}

async function validateMigration(oldRewardManager, newRewardManager, data) {
  console.log('\nValidating migration...');

  // Validate reward states
  console.log('\nValidating reward states:');
  for (const token of data.rewardTokens) {
    const oldState = await oldRewardManager.rewardState(token);
    const newState = await newRewardManager.rewardState(token);

    const statesMatch = 
      oldState.index.toString() === newState.index.toString() &&
      oldState.lastBalance.toString() === newState.lastBalance.toString();

    console.log(`\nToken: ${token}`);
    console.log('Old state:', {
      index: oldState.index.toString(),
      lastBalance: oldState.lastBalance.toString()
    });
    console.log('New state:', {
      index: newState.index.toString(),
      lastBalance: newState.lastBalance.toString()
    });
    console.log('States match:', statesMatch);

    if (!statesMatch) {
      throw new Error(`Reward state mismatch for token ${token}`);
    }
  }

  // Validate user rewards
  console.log('\nValidating user rewards:');
  for (const token of data.rewardTokens) {
    for (const position of data.positions) {
      const oldReward = await oldRewardManager.userReward(token, position);
      const newReward = await newRewardManager.userReward(token, position);

      const rewardsMatch = 
        oldReward.index.toString() === newReward.index.toString() &&
        oldReward.accrued.toString() === newReward.accrued.toString();

      console.log(`\nToken: ${token}`);
      console.log(`Position: ${position}`);
      console.log('Old reward:', {
        index: oldReward.index.toString(),
        accrued: oldReward.accrued.toString()
      });
      console.log('New reward:', {
        index: newReward.index.toString(),
        accrued: newReward.accrued.toString()
      });
      console.log('Rewards match:', rewardsMatch);

      if (!rewardsMatch) {
        throw new Error(`User reward mismatch for token ${token} and position ${position}`);
      }
    }
  }

  console.log('\nMigration validation completed successfully!');
}

async function migrateRewardManager() {
  // Read the data from the previous step
  const files = fs.readdirSync('.');
  const migrationFiles = files.filter(f => f.startsWith('reward-manager-migration-'));
  const latestFile = migrationFiles.sort().pop();
  
  if (!latestFile) {
    throw new Error('No migration data file found');
  }

  const data = JSON.parse(fs.readFileSync(latestFile));

  const [owner] = await ethers.getSigners();
  
  // Deploy new RewardManagerSpectra with all original parameters except campaignManager
  const RewardManagerSpectra = await ethers.getContractFactory("RewardManagerSpectra");
  const newRewardManager = await RewardManagerSpectra.deploy(
    "0x9BfCD3788f923186705259ae70A1192F601BeB47",  // vault
    "0x2408569177553A427dd6956E1717f2fBE1a96F1D",  // market
    "0xC63e9279410d37C0A25D094e26Cddbb73aEd7d95",  // proxyRegistry
    owner.address,  // owner - using the deployer's address
    "0x38b9B4884a5581E96eD3882AA2f7449BC321786C"   // new campaignManager
  );
  
  await newRewardManager.deployed();
  console.log('New RewardManager deployed at:', newRewardManager.address, ' with owner:', owner.address);

  const oldRewardManager = await ethers.getContractAt(
    "RewardManagerSpectra",
    "0xCaf5e9cB6F005ed95F0a00edAdd16593467eE852"
  );

  // Get and set totalShares
  const totalShares = await ethers.provider.getStorageAt(oldRewardManager.address, 0);
  console.log('Original total shares:', totalShares);

  await newRewardManager.setTotalShares(totalShares);
  console.log('Total shares set');

  // Validate totalShares
  const newTotalShares = await ethers.provider.getStorageAt(newRewardManager.address, 0);
  console.log('New total shares:', newTotalShares);
  
  if (totalShares !== newTotalShares) {
    throw new Error('Total shares mismatch after setting');
  }
  console.log('Total shares validated ✓');

  // Get and set lastRewardBlock
  const lastRewardBlock = await oldRewardManager.lastRewardBlock();
  console.log('Original last reward block:', lastRewardBlock.toString());

  await newRewardManager.setLastRewardBlock(lastRewardBlock);
  console.log('Last reward block set');

  // Validate lastRewardBlock
  const newLastRewardBlock = await newRewardManager.lastRewardBlock();
  console.log('New last reward block:', newLastRewardBlock.toString());
  
  if (lastRewardBlock.toString() !== newLastRewardBlock.toString()) {
    throw new Error('Last reward block mismatch after setting');
  }
  console.log('Last reward block validated ✓');

  // Add reward tokens
  for (const token of data.rewardTokens) {
    await newRewardManager.addRewardToken(token);
    console.log('Added reward token:', token);
  }

  console.log('Reward tokens added:', data.rewardTokens);

  // Prepare bulkSetState parameters with explicit mapping and validation
  const rewardStateParams = {
    tokens: [],
    states: []
  };

  // Get reward state for first position (they should all be the same)
  const firstPosition = data.positions[0];
  console.log('Using reward states from position:', firstPosition);

  // Build arrays ensuring token[i] matches with states[i]
  for (let i = 0; i < data.rewardTokens.length; i++) {
    const token = data.rewardTokens[i];
    const state = data.rewardStates[token];
    
    rewardStateParams.tokens.push(token);
    rewardStateParams.states.push({
      index: state.index,
      lastBalance: state.lastBalance
    });

    // Validation
    console.log(`Token ${i}:`, {
      address: token,
      index: state.index,
      lastBalance: state.lastBalance
    });
  }

  // Additional validation
  if (rewardStateParams.tokens.length !== rewardStateParams.states.length) {
    throw new Error('Mismatch in reward state parameters array lengths');
  }
  
  // Create UserRewardParams array - one entry per token
  const userRewardParams = data.rewardTokens.map(token => {
    const users = Object.keys(data.userRewards[token]);
    const rewards = users.map(user => ({
      index: data.userRewards[token][user].index,
      accrued: data.userRewards[token][user].accrued
    }));

    return {
      token,
      users,
      rewards
    };
  });

  // Validation logging
  console.log('\nUser Reward Parameters:');
  for (const param of userRewardParams) {
    console.log(`\nToken: ${param.token}`);
    console.log(`Number of users: ${param.users.length}`);
    console.log('Sample user rewards:');
    for (let i = 0; i < Math.min(2, param.users.length); i++) {
      console.log(`User ${param.users[i]}:`, param.rewards[i]);
    }
  }
  
//   // Call bulkSetRewardState
//   console.log('\nSetting reward states...');
//   await newRewardManager.bulkSetRewardState(rewardStateParams);

//   // Call bulkSetUserReward
//   console.log('\nSetting user rewards...');
//   await newRewardManager.bulkSetUserReward(userRewardParams);

// Call Set bulk state and user reward
  console.log('\nSetting reward states and user rewards...');
  await newRewardManager.bulkSetState(rewardStateParams, userRewardParams);
  
  console.log('User rewards migration completed successfully');
  
  // After bulkSetState, add validation
  await validateMigration(oldRewardManager, newRewardManager, data);
  
  // Save deployment info
  const deploymentInfo = {
    timestamp: new Date().toISOString(),
    newRewardManagerAddress: newRewardManager.address,
    migratedData: {
      rewardStateParams,
      userRewardParams
    }
  };

  fs.writeFileSync(
    `reward-manager-deployment.json`,
    JSON.stringify(deploymentInfo, null, 2)
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
