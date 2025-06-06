# ACL Ownership Update Scripts

These scripts help transfer ownership of the ACL contract from the current owner to a new owner (your connected wallet).

## Prerequisites

1. Node.js and npm installed
2. For Tenderly: Access to Tenderly fork with admin rights
3. For local Anvil: A running Anvil instance forked from mainnet

## Setup

1. Add these environment variables to your `.env` file:
   ```
   # For Anvil
   MAINNET_RPC_URL=https://eth-mainnet.alchemyapi.io/v2/YOUR_API_KEY

   # For Tenderly
   TENDERLY_FORK_URL=https://rpc.tenderly.co/fork/your-fork-id
   
   # Your deployer private key (will be used as the new owner)
   DEPLOYER_PRIVATE_KEY=0xYourPrivateKeyHere
   ```

## Available Commands

### Using Anvil (Local Testing)

1. Start an Anvil instance forked from mainnet:
   ```bash
   make anvil
   ```

2. In another terminal, run the ownership update script:
   ```bash
   make acl-update-owner-anvil
   # or directly with npm
   npm run update-acl-owner
   ```

### Using Tenderly (Fork Testing)

1. Create a Tenderly fork of mainnet
2. Add the fork URL to your `.env` file as `TENDERLY_FORK_URL`
3. Run the ownership update script:
   ```bash
   make acl-update-owner-tenderly
   # or directly with npm
   npm run update-acl-owner-tenderly
   ```

## How it Works

1. The script connects to the ACL contract at `0xE67f77af54EdA6B92f2dBaB272b8C0817ae0bCa3`
2. It impersonates the current owner (`0x074C229F0A96980D68602fA4b45B23e0164C7815`)
3. It calls `transferOwnership(newOwner)` from the current owner
4. It calls `claimOwnership()` from the new owner (derived from your private key)
5. It verifies that ownership was successfully transferred

## Troubleshooting

- **Error: cannot estimate gas**: The impersonated account may need ETH. The script attempts to fund it, but if this fails, manually send ETH to the current owner address.
- **Error: transaction reverted**: Verify that the ACL contract has the expected ownership functions and that the current owner is correct.
- **Error: cannot impersonate account**: Make sure you're using a fork with impersonation capabilities (Anvil with `--auto-impersonate` or Tenderly with admin access). 