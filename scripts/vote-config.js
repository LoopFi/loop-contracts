/**
 * Configuration file for the vote-manager.js script
 */

module.exports = {
  // Contract addresses
  contracts: {
    loopVoter: "0xadE9965484cD5f2926e26Cb95b99F183D719AbE9",
    gaugeV3: "0x090052C12A5c744542b08006197C6824ACF00187"
  },
  
  // Voter accounts - private keys should be set in environment variables
  voters: [
    {
      name: "Voter 1",
      address: "0xVOTER1_ADDRESS", // Replace with actual voter address
      envKeyName: "VOTER_PRIVATE_KEY_0"
    },
    {
      name: "Voter 2",
      address: "0xVOTER2_ADDRESS", // Replace with actual voter address
      envKeyName: "VOTER_PRIVATE_KEY_1"
    }
  ],
  
  // Default voting parameters
  defaults: {
    votes: "1000000"
  }
}; 