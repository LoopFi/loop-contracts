const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

// Check for dotenv and load if available
try {
  require('dotenv').config();
} catch (error) {
  console.log('dotenv not installed, skipping .env file loading');
}

// Get the network from command line or default to local
let network = 'local';
if (process.argv.length > 2 && process.argv[2].startsWith('--network=')) {
  network = process.argv[2].split('=')[1];
  // Remove the network argument from process.argv
  process.argv.splice(2, 1);
}

console.log(`Using network: ${network}`);

// Load configuration for the right network
let config;
try {
  // First try to load a network-specific config
  const configPath = `./vote-config-${network}.js`;
  try {
    config = require(configPath);
    console.log(`Loaded network-specific configuration from ${configPath}`);
  } catch (error) {
    // Fall back to default config
    config = require('./vote-config');
    console.log(`Loaded default configuration from ./vote-config.js`);
  }
  
  console.log(`Loaded configuration with ${config.voters.length} voters`);
} catch (error) {
  console.error(`Error loading configuration: ${error.message}`);
  console.error(`Make sure vote-config.js exists in the scripts directory.`);
  process.exit(1);
}

/**
 * Gets a voter's private key from environment variables
 * @param {number} voterIndex - The index of the voter in the config
 * @returns {string} The private key
 */
function getVoterPrivateKey(voterIndex) {
  if (voterIndex >= config.voters.length) {
    throw new Error(`Invalid voter index: ${voterIndex}. Only ${config.voters.length} voters available.`);
  }
  
  const voter = config.voters[voterIndex];
  const privateKey = process.env[voter.envKeyName];
  
  if (!privateKey) {
    throw new Error(`Private key not found in environment variable ${voter.envKeyName}`);
  }
  
  return privateKey;
}

// Function to add voters to LoopVoter
async function addVoters(loopVoterAddress, voterAddresses) {
  const [deployer] = await ethers.getSigners();
  console.log(`Adding voters using deployer: ${await deployer.getAddress()}`);
  
  // Attach to the LoopVoter contract
  const loopVoter = await ethers.getContractAt("LoopVoter", loopVoterAddress);
  
  // Check if the deployer is the owner
  const owner = await loopVoter.owner();
  if (owner.toLowerCase() !== (await deployer.getAddress()).toLowerCase()) {
    console.error(`Error: Deployer is not the owner of the LoopVoter contract`);
    console.error(`Owner: ${owner}`);
    console.error(`Deployer: ${await deployer.getAddress()}`);
    return false;
  }
  
  // Add each voter
  for (const voterAddress of voterAddresses) {
    console.log(`Adding voter: ${voterAddress}`);
    
    // Check if already a voter
    const isVoter = await loopVoter.voters(voterAddress);
    if (isVoter) {
      console.log(`Voter ${voterAddress} is already registered`);
      continue;
    }
    
    // Add the voter
    try {
      const tx = await loopVoter.addVoter(voterAddress);
      await tx.wait();
      console.log(`Successfully added voter ${voterAddress}, tx: ${tx.hash}`);
    } catch (error) {
      console.error(`Error adding voter ${voterAddress}: ${error.message}`);
      return false;
    }
  }
  
  return true;
}

// Function to vote for a token with GaugeV3
async function voteForToken(
  gaugeV3Address, 
  voterIndex, 
  userAddress, 
  tokenAddress, 
  lpSide, 
  votes
) {
  try {
    // Get the private key from environment variables
    const voterPrivateKey = getVoterPrivateKey(voterIndex);
    
    // Create a wallet from the private key
    const wallet = new ethers.Wallet(voterPrivateKey, ethers.provider);
    console.log(`Voting with voter: ${wallet.address}`);
    
    // Attach to the GaugeV3 contract
    const gaugeV3 = await ethers.getContractAt("GaugeV3", gaugeV3Address, wallet);
    
    // Prepare the extraData containing token and lpSide
    // lpSide is 0 for minimum quota or 1 for the maximum.
    const extraData = ethers.utils.defaultAbiCoder.encode(
      ['address', 'uint8'], 
      [tokenAddress, lpSide]
    );
    
    console.log(`Voting for user: ${userAddress}`);
    console.log(`Token: ${tokenAddress}`);
    console.log(`LP Side: ${lpSide === 0 ? 'Minimum (Borrower)' : 'Maximum (Lender)'}`);
    console.log(`Votes: ${votes}`);
    
    // Call the vote function
    const tx = await gaugeV3.vote(userAddress, votes, extraData);
    const receipt = await tx.wait();
    console.log(`Vote successful, tx: ${tx.hash}`);
    return receipt;
  } catch (error) {
    console.error(`Error voting: ${error.message}`);
    // If we have more detailed error data, display it
    if (error.data) {
      console.error(`Error data: ${error.data}`);
    }
    return null;
  }
}

// Function to get configured accounts
async function getVoterAccounts() {
  console.log("Available voter accounts:");
  for (let i = 0; i < config.voters.length; i++) {
    const voter = config.voters[i];
    const hasKey = process.env[voter.envKeyName] ? "✓" : "✗";
    console.log(`[${i}] ${voter.name} (${voter.address}) - Private key in env: ${hasKey}`);
  }
}

/**
 * Calculates the necessary votes for each side to achieve a target rate for a token
 * @param {number} targetRate - The desired rate to achieve (in basis points)
 * @param {number} minRate - The minimum rate for the token
 * @param {number} maxRate - The maximum rate for the token
 * @param {number} totalVotingPower - Total voting power to distribute
 * @returns {Object} The distribution of votes for CA side and LP side
 */
function calculateVotesForTargetRate(targetRate, minRate, maxRate, totalVotingPower) {
  // Rate computation formula from GaugeV3.sol:
  // rate = (minRate * votesCaSide + maxRate * votesLpSide) / totalVotes
  
  // Ensure the target rate is within the allowed range
  if (targetRate < minRate || targetRate > maxRate) {
    throw new Error(`Target rate ${targetRate} is outside the allowed range [${minRate}, ${maxRate}]`);
  }
  
  // Calculate the ratio: votesCaSide / votesLpSide = (maxRate - targetRate) / (targetRate - minRate)
  const numerator = maxRate - targetRate;
  const denominator = targetRate - minRate;
  
  // Handle edge cases
  if (denominator === 0) {
    // Target rate equals minRate, put all votes on CA side
    return { 
      votesCaSide: totalVotingPower, 
      votesLpSide: 0,
      ratio: "∞" // Infinity ratio
    };
  }
  
  if (numerator === 0) {
    // Target rate equals maxRate, put all votes on LP side
    return { 
      votesCaSide: 0, 
      votesLpSide: totalVotingPower,
      ratio: "0" // Zero ratio
    };
  }
  
  // Calculate the ratio
  const ratio = numerator / denominator;
  
  // Calculate votes for each side
  const totalRatioParts = ratio + 1; // ratio = caSide/lpSide, so totalParts = (caSide + lpSide)/lpSide = ratio + 1
  const votesLpSide = Math.floor(totalVotingPower / totalRatioParts);
  const votesCaSide = totalVotingPower - votesLpSide;
  
  return {
    votesCaSide,
    votesLpSide,
    ratio: ratio.toFixed(4)
  };
}

/**
 * Gets the min and max rates for a token from the gauge contract
 * @param {string} gaugeV3Address - The address of the GaugeV3 contract
 * @param {string} tokenAddress - The token address
 * @returns {Promise<{minRate: number, maxRate: number}>} The min and max rates
 */
async function getTokenRateParams(gaugeV3Address, tokenAddress) {
  const gaugeV3 = await ethers.getContractAt("GaugeV3", gaugeV3Address);
  
  // Get the quota rate parameters for the token
  const params = await gaugeV3.quotaRateParams(tokenAddress);
  
  return {
    minRate: parseInt(params.minRate),
    maxRate: parseInt(params.maxRate)
  };
}

// Function to vote for a specific target rate
async function voteForTargetRate(
  gaugeV3Address,
  voterIndex,
  userAddress,
  tokenAddress,
  targetRate,
  totalVotes
) {
  console.log(`Getting rate parameters for token ${tokenAddress}...`);
  
  // Get the min and max rates for the token
  const { minRate, maxRate } = await getTokenRateParams(gaugeV3Address, tokenAddress);
  console.log(`Token rate range: [${minRate}, ${maxRate}] basis points`);
  
  // Parse the target rate and total votes
  const targetRateBps = parseInt(targetRate);
  const totalVotesParsed = totalVotes ? parseInt(totalVotes) : parseInt(config.defaults.votes);
  
  console.log(`Target rate: ${targetRateBps} basis points`);
  console.log(`Total voting power: ${totalVotesParsed}`);
  
  // Calculate the votes needed for each side
  const voteDistribution = calculateVotesForTargetRate(
    targetRateBps,
    minRate,
    maxRate,
    totalVotesParsed
  );
  
  console.log(`Vote distribution for target rate ${targetRateBps}:`);
  console.log(`  CA side (minimum) votes: ${voteDistribution.votesCaSide}`);
  console.log(`  LP side (maximum) votes: ${voteDistribution.votesLpSide}`);
  console.log(`  Ratio (CA/LP): ${voteDistribution.ratio}`);
  
  // Make sure we have a voter configured
  if (voterIndex >= config.voters.length) {
    console.error(`Error: Invalid voter index. Only ${config.voters.length} voters available.`);
    return false;
  }
  
  // Check if we need to vote for both sides
  let result = true;
  
  // Vote for CA side (minimum) if needed
  if (voteDistribution.votesCaSide > 0) {
    console.log(`Voting for minimum (CA side) with ${voteDistribution.votesCaSide} votes...`);
    const caSideResult = await voteForToken(
      gaugeV3Address,
      voterIndex,
      userAddress,
      tokenAddress,
      0, // 0 = CA side (minimum)
      voteDistribution.votesCaSide.toString()
    );
    
    if (!caSideResult) {
      console.error("Failed to vote for CA side");
      result = false;
    }
  }
  
  // Vote for LP side (maximum) if needed
  if (voteDistribution.votesLpSide > 0) {
    console.log(`Voting for maximum (LP side) with ${voteDistribution.votesLpSide} votes...`);
    const lpSideResult = await voteForToken(
      gaugeV3Address,
      voterIndex,
      userAddress,
      tokenAddress,
      1, // 1 = LP side (maximum)
      voteDistribution.votesLpSide.toString()
    );
    
    if (!lpSideResult) {
      console.error("Failed to vote for LP side");
      result = false;
    }
  }
  
  // Calculate the expected rate based on the votes we submitted
  const expectedRate = voteDistribution.votesCaSide + voteDistribution.votesLpSide === 0
    ? minRate
    : (minRate * voteDistribution.votesCaSide + maxRate * voteDistribution.votesLpSide) / 
      (voteDistribution.votesCaSide + voteDistribution.votesLpSide);
  
  console.log(`Expected resulting rate: ~${Math.round(expectedRate)} basis points`);
  
  return result;
}

// Command execution function
async function main() {
  // If the network was passed via --network flag, the first arg will be the command
  const command = process.argv[2];
  
  switch (command) {
    case "list-voters":
      await getVoterAccounts();
      break;
      
    case "add-voters":
      const voterAddresses = config.voters.map(voter => voter.address);
      const success = await addVoters(config.contracts.loopVoter, voterAddresses);
      if (success) {
        console.log("All voters added successfully");
      } else {
        console.error("Failed to add all voters");
      }
      break;
      
    case "vote":
      // Get parameters from command line
      const voterIndex = parseInt(process.argv[3] || "0");
      const userAddress = process.argv[4];
      const tokenAddress = process.argv[5];
      const lpSide = parseInt(process.argv[6]);
      const votes = process.argv[7] || config.defaults.votes;
      
      if (!userAddress || !tokenAddress || lpSide === undefined) {
        console.error("Usage: npx hardhat run scripts/vote-manager.js vote [voterIndex] [userAddress] [tokenAddress] [lpSide] [votes]");
        console.error("  lpSide: 0 for minimum (borrower side), 1 for maximum (lender side)");
        process.exit(1);
      }
      
      const result = await voteForToken(
        config.contracts.gaugeV3,
        voterIndex,
        userAddress,
        tokenAddress,
        lpSide,
        votes
      );
      
      if (result) {
        console.log("Vote registered successfully");
      } else {
        console.error("Failed to register vote");
      }
      break;
      
    case "vote-for-rate":
      // Get parameters from command line
      const rateVoterIndex = parseInt(process.argv[3] || "0");
      const rateUserAddress = process.argv[4];
      const rateTokenAddress = process.argv[5];
      const targetRate = process.argv[6]; // Target rate in basis points
      const rateTotalVotes = process.argv[7] || config.defaults.votes;
      
      if (!rateUserAddress || !rateTokenAddress || !targetRate) {
        console.error("Usage: npx hardhat run scripts/vote-manager.js vote-for-rate [voterIndex] [userAddress] [tokenAddress] [targetRate] [totalVotes]");
        console.error("  targetRate: Desired rate in basis points (e.g., 800 for 8%)");
        console.error("  totalVotes: Total voting power to use (default: configured default votes)");
        process.exit(1);
      }
      
      const rateResult = await voteForTargetRate(
        config.contracts.gaugeV3,
        rateVoterIndex,
        rateUserAddress,
        rateTokenAddress,
        targetRate,
        rateTotalVotes
      );
      
      if (rateResult) {
        console.log("Votes for target rate registered successfully");
      } else {
        console.error("Failed to register votes for target rate");
      }
      break;
      
    case "check-voter-status":
      const loopVoter = await ethers.getContractAt("LoopVoter", config.contracts.loopVoter);
      
      for (const voter of config.voters) {
        const isVoter = await loopVoter.voters(voter.address);
        console.log(`Voter ${voter.name} (${voter.address}): ${isVoter ? 'Registered' : 'Not registered'}`);
      }
      break;
      
    case "help":
    default:
      console.log(`
Loop Voting Manager
===================

Usage:
  npx hardhat run scripts/vote-manager.js [--network=<network>] <command> [options]

Networks:
  --network=local       Run on local Anvil instance (default)
  --network=bsc         Run on BSC
  --network=mainnet     Run on Ethereum Mainnet
  --network=tenderly    Run on Tenderly

Commands:
  list-voters            - List configured voter accounts
  add-voters             - Add configured voters to the LoopVoter contract
  vote [idx] [user] [token] [lpSide] [votes] 
                         - Register a vote for a token
                         - idx: Voter index (0 or 1)
                         - user: User address to vote for
                         - token: Token address to vote for
                         - lpSide: 0 for minimum (borrower side), 1 for maximum (lender side) - REQUIRED
                         - votes: Amount of votes to cast (default: ${config.defaults.votes})
  vote-for-rate [idx] [user] [token] [targetRate] [totalVotes]
                         - Register votes to achieve a specific target rate
                         - idx: Voter index (0 or 1)
                         - user: User address to vote for
                         - token: Token address to vote for
                         - targetRate: Target rate in basis points (e.g., 800 for 8%)
                         - totalVotes: Total voting power to use (optional)
  check-voter-status     - Check if each configured voter is registered in the LoopVoter contract

Environment Variables:
  Set environment variables for voter private keys:
  ${config.voters.map(voter => `  ${voter.envKeyName} - Private key for ${voter.name}`).join('\n  ')}

Examples:
  npx hardhat run scripts/vote-manager.js --network=local list-voters
  npx hardhat run scripts/vote-manager.js --network=bsc add-voters
  npx hardhat run scripts/vote-manager.js --network=mainnet vote 0 0x123... 0x456... 0 1000000
  npx hardhat run scripts/vote-manager.js vote-for-rate 0 0x123... 0x456... 800 1000000
      `);
  }
}

// Execute the script
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 