# Deployer Funding Guide

This guide explains how the automatic deployer funding works when running deployment scripts on Anvil.

## Overview

When running the Bitlayer deployment script on Anvil (local development), the deployer account is automatically funded if needed. This ensures smooth deployments without manual intervention.

## How It Works

### 1. Anvil Configuration

The `anvil-bitlayer` command in the Makefile now includes funding flags:

```makefile
anvil-bitlayer   :; anvil --fork-url $(BITLAYER_RPC_URL) --auto-impersonate --balance 10000000
```

- `--auto-impersonate`: Allows impersonating any account
- `--balance 10000000`: Sets default balance to 10M ETH for new accounts

### 2. Automatic Funding in Deploy Script

The `deploy_bitlayer.js` script includes automatic funding logic:

1. **Detection**: Checks if running on local Anvil (chainId 31337)
2. **Balance Check**: Verifies deployer has sufficient balance (>100 ETH)
3. **Auto-Fund**: If balance is low, uses `anvil_setBalance` RPC to set deployer balance to 1000 ETH
4. **Logging**: Provides clear feedback about funding status

**Note**: This uses Anvil's low-level `anvil_setBalance` RPC call to directly set the balance, which works even if the deployer account has zero initial balance.

## Usage

### Start Anvil with Bitlayer Fork

```bash
make anvil-bitlayer
```

This starts Anvil with:
- Bitlayer mainnet fork
- Auto-impersonation enabled
- 10M ETH default balance

### Run Bitlayer Deployment

```bash
make deploy-anvil-bitlayer
```

The script will:
1. Automatically detect it's running on Anvil
2. Check deployer balance
3. Fund deployer if needed (< 100 ETH)
4. Proceed with deployment

## Example Output

```
🚀 Starting Bitlayer deployment...

=== CHECKING DEPLOYER FUNDING ===
💰 Deployer: 0x1234...5678
💰 Current balance: 0.0 ETH
🔧 Detected local anvil network
⚠️  Low balance detected. Funding deployer with 1000 ETH using anvil_setBalance...
🔧 Setting balance for 0x1234...5678 to 0x3635c9adc5dea00000
✅ Deployer funded! New balance: 1000.0 ETH

=== CHECKING NETWORK CONNECTION ===
✅ Connected to network: unknown (Chain ID: 31337)
📦 Current block: 12345
⛽ Actual gas price: 1000000000 wei (1.0 gwei)
💰 Deployer: 0x1234...5678
💰 Balance: 1050000000000000000000 wei (1050.0 ETH)
✅ Sufficient balance for deployment
```

## Testing the Funding Mechanism

A test script is provided to verify the funding mechanism:

```bash
node test-funding.js --network local
```

This will:
1. Test funding detection logic
2. Test actual funding functionality
3. Verify balance increases correctly

## Manual Funding (Alternative)

If you need to manually fund an account on Anvil, you can use the low-level RPC call:

```javascript
// Fund account with 1000 ETH using anvil_setBalance
const fundAmount = ethers.utils.parseEther('1000');
const fundAmountHex = fundAmount.toHexString();

await ethers.provider.send("anvil_setBalance", [
  '0x1234567890123456789012345678901234567890', // address to fund
  fundAmountHex // amount in hex
]);
```

This approach works even if the target account has zero balance initially.

## Network Detection

The funding mechanism only activates on local Anvil networks:
- Chain ID 31337 (default Anvil)
- Network name 'unknown' (forked networks)

On live networks (mainnet, testnet), funding is automatically skipped for safety.

## Troubleshooting

### "Insufficient funds" error
- Ensure Anvil is running with `--balance` flag
- Check that the funding function is being called
- Verify network detection is working correctly

### Funding not triggered
- Confirm you're running on local Anvil (chainId 31337)
- Check that balance is actually below 100 ETH threshold
- Look for funding logs in deployment output

### Gas estimation failures
- Ensure deployer has sufficient balance after funding
- Check that Anvil is properly forked from Bitlayer
- Verify all required environment variables are set

## Environment Variables

Make sure these are set in your `.env` file:

```bash
BITLAYER_RPC_URL=https://rpc.bitlayer.org
DEPLOYER_PRIVATE_KEY=your_private_key_here
```

## Safety Features

- **Network Detection**: Only funds on local Anvil, never on live networks
- **Balance Threshold**: Only funds if balance < 100 ETH
- **Error Handling**: Deployment continues even if funding fails
- **Logging**: Clear feedback about all funding operations
