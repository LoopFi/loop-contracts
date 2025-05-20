const { ethers } = require('hardhat');
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
  // Determine if we're using Anvil or Tenderly
  const networkName = hre.network.name;
  console.log(`Running on network: ${networkName}`);

  // Check for required environment variables
  if (!process.env.DEPLOYER_PRIVATE_KEY) {
    throw new Error("DEPLOYER_PRIVATE_KEY environment variable is required");
  }

  // Get the provider
  const provider = ethers.provider;

  // Create wallet from private key and connect to provider
  // Note: With hardhat, we'd normally use getSigners(), but we're using private key
  // to be consistent with the Tenderly script
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
  
  // Impersonate the current owner
  console.log(`Impersonating current owner: ${currentOwnerFromContract}`);
  await provider.send("anvil_impersonateAccount", [currentOwnerFromContract]);
  
  // Create a signer for the impersonated account
  const impersonatedSigner = await ethers.getImpersonatedSigner(currentOwnerFromContract);
  
  // Fund the impersonated account if necessary (on Anvil)
  if (networkName === 'localhost' || networkName === 'hardhat') {
    await deployerWallet.sendTransaction({
      to: currentOwnerFromContract,
      value: ethers.utils.parseEther("1.0")
    });
    console.log(`Funded the impersonated account with 1 ETH`);
  }
  
  // Connect contract to impersonated signer
  const aclContractAsOwner = aclContract.connect(impersonatedSigner);
  
  // Step 1: Transfer ownership from current owner to new owner
  console.log(`Transferring ownership to ${newOwnerAddress}...`);
  const tx1 = await aclContractAsOwner.transferOwnership(newOwnerAddress);
  await tx1.wait();
  console.log(`Ownership transfer initiated. Transaction hash: ${tx1.hash}`);
  
  // Step 2: Claim ownership as the new owner
  console.log(`Claiming ownership as new owner...`);
  const aclContractAsNewOwner = aclContract.connect(deployerWallet);
  const tx2 = await aclContractAsNewOwner.claimOwnership();
  await tx2.wait();
  console.log(`Ownership claimed. Transaction hash: ${tx2.hash}`);
  
  // Verify the new owner
  const finalOwner = await aclContract.owner();
  console.log(`Final owner: ${finalOwner}`);
  
  if (finalOwner.toLowerCase() === newOwnerAddress.toLowerCase()) {
    console.log('✅ Ownership successfully transferred and claimed!');
  } else {
    console.log('❌ Ownership transfer failed!');
  }
  
  // Stop impersonating
  await provider.send("anvil_stopImpersonatingAccount", [currentOwnerFromContract]);
  console.log(`Stopped impersonating ${currentOwnerFromContract}`);
}

// Handle errors
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 