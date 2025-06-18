const { ethers } = require('ethers');
require('dotenv').config();

// ACL contract details
const ACL_ADDRESS = '0xE67f77af54EdA6B92f2dBaB272b8C0817ae0bCa3';
const CURRENT_OWNER = '0x074C229F0A96980D68602fA4b45B23e0164C7815';

// Simple ABI for ACL contract containing just the ownership functions
const ACL_ABI = [
  "function transferOwnership(address newOwner) external",
  "function pendingOwner() external view returns (address)",
  "function claimOwnership() external",
  "function owner() external view returns (address)"
];

async function main() {
  // Check for required environment variables
  if (!process.env.TENDERLY_FORK_URL) {
    throw new Error("TENDERLY_FORK_URL environment variable is required");
  }
  
  if (!process.env.DEPLOYER_PRIVATE_KEY) {
    throw new Error("DEPLOYER_PRIVATE_KEY environment variable is required");
  }
  
  // Set up providers - use ethers v5 style
  const provider = new ethers.providers.JsonRpcProvider(process.env.TENDERLY_FORK_URL);
  console.log("Connected to Tenderly RPC");
  
  // Create wallet from private key and get the address
  const deployerWallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
  const newOwnerAddress = await deployerWallet.getAddress();
  console.log(`New owner will be: ${newOwnerAddress}`);

  // Connect to ACL contract
  const aclContract = new ethers.Contract(ACL_ADDRESS, ACL_ABI, provider);
  
  // Get current owner from contract
  const currentOwnerFromContract = await aclContract.owner();
  console.log(`Current owner from contract: ${currentOwnerFromContract}`);
  
  if (currentOwnerFromContract.toLowerCase() !== CURRENT_OWNER.toLowerCase()) {
    console.log(`WARNING: Current owner in contract (${currentOwnerFromContract}) doesn't match expected owner (${CURRENT_OWNER})`);
    // Continue anyway, but with the owner from the contract
  }
  
  // Fund the current owner account
  console.log(`Setting balance for ${currentOwnerFromContract}`);
  await provider.send('tenderly_setBalance', [
    [currentOwnerFromContract], 
    "0x6C6B935B8BBD400000" // 2000 ETH in hex
  ]);
  
  // Step 1: Transfer ownership from current owner to new owner
  console.log(`Transferring ownership to ${newOwnerAddress}...`);
  const txData = aclContract.interface.encodeFunctionData("transferOwnership", [newOwnerAddress]);
  const tx1 = await provider.send('eth_sendTransaction', [{
    from: currentOwnerFromContract,
    to: ACL_ADDRESS,
    data: txData
  }]);
  console.log(`Ownership transfer initiated. Transaction hash: ${tx1}`);
  
  // Wait for transaction
  await provider.waitForTransaction(tx1);
  
  // Check pending owner
  const pendingOwner = await aclContract.pendingOwner();
  console.log(`Pending owner is now: ${pendingOwner}`);
  
  // Fund the new owner account if using admin RPC - not needed if we're using a real wallet
  console.log(`Setting balance for ${newOwnerAddress} (if needed)`);
  try {
    await provider.send('tenderly_setBalance', [
      [newOwnerAddress], 
      "0x6C6B935B8BBD400000" // 2000 ETH in hex
    ]);
  } catch (error) {
    console.log(`Note: Could not set balance for ${newOwnerAddress}. This is normal if not using admin RPC.`);
  }
  
  // Step 2: Claim ownership as the new owner using the deployer wallet
  console.log(`Claiming ownership as new owner...`);
  
  // Connect contract to deployer wallet
  const aclContractWithDeployer = aclContract.connect(deployerWallet);
  
  // Call claimOwnership directly with the wallet
  const tx2 = await aclContractWithDeployer.claimOwnership();
  console.log(`Ownership claim transaction sent: ${tx2.hash}`);
  await tx2.wait();
  console.log(`Ownership claimed. Transaction confirmed.`);
  
  // Verify the new owner
  const finalOwner = await aclContract.owner();
  console.log(`Final owner: ${finalOwner}`);
  
  if (finalOwner.toLowerCase() === newOwnerAddress.toLowerCase()) {
    console.log('✅ Ownership successfully transferred and claimed!');
  } else {
    console.log('❌ Ownership transfer failed!');
  }
}

// Handle errors
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 