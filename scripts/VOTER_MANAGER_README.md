# LoopFi Voter Manager

This utility provides tools for managing voters and voting in the LoopFi protocol. It allows you to:

1. Add voters to the LoopVoter contract
2. Check voter status
3. Vote for tokens via the GaugeV3 contract
4. Calculate and submit votes to achieve a specific target rate

## Setup

1. Make sure you have the correct contract addresses for `LoopVoter` and `GaugeV3` in your deployment file.

2. Configure your voters in `vote-config.js` (default) or network-specific configuration files:
   
   For default configuration:
   ```javascript
   // vote-config.js
   module.exports = {
     contracts: {
       loopVoter: "0xe1987f6cD0b8823a033c29d640596757492479BD",
       gaugeV3: "0x0D7909318B497Da3060BcD371448E4629be2705D"
     },
     voters: [
       {
         name: "Protocol Voter 1",
         address: "0x123abc...",
         envKeyName: "VOTER_PRIVATE_KEY_0" // Name of the environment variable containing the private key
       },
       {
         name: "Protocol Voter 2",
         address: "0x456def...",
         envKeyName: "VOTER_PRIVATE_KEY_1"
       }
     ],
     defaults: {
       votes: "1000000" // Default voting power
     }
   };
   ```

   For network-specific configuration (e.g., BSC):
   ```javascript
   // vote-config-bsc.js
   module.exports = {
     contracts: {
       loopVoter: "0xBSC_LOOP_VOTER_ADDRESS", // BSC-specific address
       gaugeV3: "0xBSC_GAUGE_V3_ADDRESS" // BSC-specific address
     },
     voters: [
       {
         name: "BSC Voter 1",
         address: "0xBSC_VOTER1_ADDRESS",
         envKeyName: "BSC_VOTER_PRIVATE_KEY_0"
       },
       // ...
     ],
     defaults: {
       votes: "1000000"
     }
   };
   ```

3. Set up environment variables for voter private keys:

   Using a `.env` file (requires the `dotenv` package to be installed):
   ```
   # Local network keys
   VOTER_PRIVATE_KEY_0=0xabcdef123456...
   VOTER_PRIVATE_KEY_1=0x789012ghijkl...
   
   # BSC network keys
   BSC_VOTER_PRIVATE_KEY_0=0xbsckey1...
   BSC_VOTER_PRIVATE_KEY_1=0xbsckey2...
   ```

   Or directly in your terminal:
   ```bash
   export VOTER_PRIVATE_KEY_0=0xabcdef123456...
   ```

   ⚠️ **IMPORTANT: Never commit your `.env` file to your repository. Add it to your `.gitignore` file.**

## Usage

### Using the Makefile

The project includes Makefile commands for common voter management operations:

```bash
# Get help
make voters-help

# Local (Anvil) Network Commands
make voters-list-local           # List configured voters
make voters-add-local            # Add voters to LoopVoter
make voters-status-local         # Check voter status in LoopVoter

# BSC Network Commands
make voters-list-bsc
make voters-add-bsc
make voters-status-bsc

# Mainnet Network Commands
make voters-list-mainnet
make voters-add-mainnet
make voters-status-mainnet

# For voting commands that require parameters:
make voters-vote-local ARGS="0 0x123... 0x456... 0 1000000"
make voters-rate-local ARGS="0 0x123... 0x456... 800 1000000"
```

### Using the Script Directly

The script provides several commands you can run directly:

```bash
npx hardhat run scripts/vote-manager.js --network=<network> <command> [options]
```

Available networks:
- `local` - Run on local Anvil instance (default)
- `bsc` - Run on BSC
- `mainnet` - Run on Ethereum Mainnet
- `tenderly` - Run on Tenderly

#### List Configured Voters

```bash
npx hardhat run scripts/vote-manager.js --network=local list-voters
```

This will show all voters configured in your `vote-config.js` file and whether their private keys are available in environment variables.

#### Add Voters to LoopVoter

```bash
npx hardhat run scripts/vote-manager.js --network=local add-voters
```

This adds all configured voters to the LoopVoter contract. Note:
- The deployer account (first account in hardhat) must be the owner of the LoopVoter contract
- Voters that are already registered will be skipped

#### Check Voter Status

```bash
npx hardhat run scripts/vote-manager.js --network=local check-voter-status
```

This checks if each configured voter is registered in the LoopVoter contract and displays their status.

#### Vote for a Token

```bash
npx hardhat run scripts/vote-manager.js --network=local vote [voterIndex] [userAddress] [tokenAddress] [lpSide] [votes]
```

Parameters:
- `voterIndex`: Index of the voter in your configuration (0, 1, etc.)
- `userAddress`: The address of the user to vote for
- `tokenAddress`: The address of the token to vote for
- `lpSide`: **Required** - 0 for minimum (borrower side), 1 for maximum (lender side)
- `votes`: Amount of votes to cast (optional, defaults to config value)

Example:
```bash
npx hardhat run scripts/vote-manager.js --network=local vote 0 0xUSER_ADDRESS 0xTOKEN_ADDRESS 0 1000000
```

#### Vote for a Specific Rate

```bash
npx hardhat run scripts/vote-manager.js --network=local vote-for-rate [voterIndex] [userAddress] [tokenAddress] [targetRate] [totalVotes]
```

This command calculates the necessary vote distribution to achieve a specific interest rate and submits the votes accordingly.

Parameters:
- `voterIndex`: Index of the voter in your configuration (0, 1, etc.)
- `userAddress`: The address of the user to vote for
- `tokenAddress`: The address of the token to vote for
- `targetRate`: The desired rate in basis points (e.g., 800 for 8%)
- `totalVotes`: Total voting power to use (optional, defaults to config value)

Example:
```bash
npx hardhat run scripts/vote-manager.js --network=local vote-for-rate 0 0xUSER_ADDRESS 0xTOKEN_ADDRESS 800 1000000
```

This will:
1. Fetch the min and max rates for the token from the GaugeV3 contract
2. Calculate how many votes should go to each side (minimum/maximum) to achieve the target rate
3. Submit the necessary votes to both sides

## How Voting Works

The voting mechanism works as follows:

1. Each configured voter can call the `vote()` function on the GaugeV3 contract
2. The vote includes:
   - `user`: The address of the user to vote for
   - `votes`: The amount of voting power to assign
   - `extraData`: Encoded data containing:
     - `token`: The token address to vote for
     - `lpSide`: The side parameter that determines if votes go toward the minimum value (0) or maximum value (1)

The `lpSide` parameter is critical as it determines whether your vote contributes toward the minimum (borrower side) or maximum (lender side) values for the token in the gauge contract.

### How Rates Are Calculated

The GaugeV3 contract calculates the interest rate using this formula:

```
rate = totalVotes == 0
    ? minRate
    : (minRate * votesCaSide + maxRate * votesLpSide) / totalVotes
```

Where:
- `minRate` is the minimum rate set for the token
- `maxRate` is the maximum rate set for the token
- `votesCaSide` is the total votes for the minimum (CA/borrower side)
- `votesLpSide` is the total votes for the maximum (LP/lender side)
- `totalVotes` is the sum of votes for both sides

The `vote-for-rate` command uses this formula to calculate the exact distribution of votes needed to achieve the target rate.

Behind the scenes, the script:
1. Creates a wallet using the voter's private key (loaded from environment variables)
2. Calculates the necessary distribution of votes between minimum and maximum sides
3. Encodes the token address and lpSide into extraData
4. Calls the vote function on the GaugeV3 contract for each side as needed

## Troubleshooting

- **Error: Deployer is not the owner**: The account used to run the script is not the owner of the LoopVoter contract. Check your accounts and make sure you're using the right one.
- **Error: Invalid voter index**: The voter index provided is out of bounds. Check your configuration.
- **Error: Private key not found in environment variable**: The environment variable for the voter's private key is not set. Check your environment variables.
- **Error: lpSide is required**: You must specify whether to vote for minimum (0) or maximum (1) value.
- **Error: Target rate out of range**: The target rate must be between the minimum and maximum rates set for the token.
- **Error adding voter**: There was an error adding a voter. Check the error message for details.
- **Error voting**: There was an error voting. Check the error message for details. 