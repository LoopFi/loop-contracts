// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {CDPVault, IRewardManager, CDPVaultConstants, CDPVaultConfig} from "./CDPVault.sol";

interface ISpectraRewardManager is IRewardManager {
    function campaignManager() external view returns (address);
    function updateIndexRewards() external;
}

interface ICampaignManager {
    function claim(
        address token,
        address rewardToken,
        uint256 earnedAmount,
        uint256 claimAmount,
        bytes32[] calldata merkleProof
    ) external;
}

contract CDPVaultSpectra is CDPVault {
    constructor(CDPVaultConstants memory constants, CDPVaultConfig memory config) CDPVault(constants, config) {}

    function claimSpectraRewards(
        address rewardToken,
        uint256 earnedAmount,
        uint256 claimAmount,
        bytes32[] calldata merkleProof
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(rewardManager) != address(0)) {
            ISpectraRewardManager spectraRewardManager = ISpectraRewardManager(address(rewardManager));
            ICampaignManager(spectraRewardManager.campaignManager()).claim(
                address(token),
                rewardToken,
                earnedAmount,
                claimAmount,
                merkleProof
            );
            spectraRewardManager.updateIndexRewards();
        }
    }
}
