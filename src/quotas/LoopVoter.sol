// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IVotingContractV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IVotingContractV3.sol";
import {UserVoteLockData, MultiVote, VotingContractStatus, EPOCHS_TO_WITHDRAW} from "@gearbox-protocol/core-v3/contracts/interfaces/IGearStakingV3.sol";

import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";

// EXCEPTIONS
import "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";

/// @title Loop Voter
contract LoopVoter is ACLNonReentrantTrait {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Contract version
    uint256 public constant version = 3_00;

    uint256 public constant EPOCH_LENGTH = 1 days;

    /// @notice Timestamp of the first epoch of voting
    uint256 public immutable firstEpochTimestamp;

    /// @dev Mapping from user to their stake amount and tokens available for voting
    mapping(address => UserVoteLockData) internal voteLockData;

    constructor(address _addressProvider, uint256 _firstEpochTimestamp) ACLNonReentrantTrait(_addressProvider) {
        firstEpochTimestamp = _firstEpochTimestamp; // U:[GS-01]
    }

    /// @notice Sets the voting power for a user
    /// @param amount The amount of voting power to set
    /// @param to The address to set the voting power for
    function setVotingPower(uint96 amount, address to) external controllerOnly {
        UserVoteLockData storage vld = voteLockData[to];
        vld.totalStaked = amount;
        vld.available = amount;
    }

    /// @notice Performs a sequence of votes
    /// @param votes Sequence of votes to perform, see `MultiVote`
    function multivote(MultiVote[] calldata votes) external nonReentrant {
        _multivote(msg.sender, votes); // U: [GS-04]
    }

    /// @dev Implementation of `multivote`
    function _multivote(address user, MultiVote[] calldata votes) internal {
        uint256 len = votes.length;
        if (len == 0) return;

        UserVoteLockData storage vld = voteLockData[user];

        for (uint256 i = 0; i < len; ) {
            MultiVote calldata currentVote = votes[i];

            if (currentVote.isIncrease) {
                if (vld.available < currentVote.voteAmount) revert InsufficientBalanceException();
                unchecked {
                    vld.available -= currentVote.voteAmount;
                }

                IVotingContractV3(currentVote.votingContract).vote(user, currentVote.voteAmount, currentVote.extraData);
            } else {
                IVotingContractV3(currentVote.votingContract).unvote(
                    user,
                    currentVote.voteAmount,
                    currentVote.extraData
                );
                vld.available += currentVote.voteAmount;
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the current global voting epoch
    function getCurrentEpoch() public view returns (uint16) {
        if (block.timestamp < firstEpochTimestamp) return 0; // U:[GS-01]
        unchecked {
            return uint16((block.timestamp - firstEpochTimestamp) / EPOCH_LENGTH) + 1; // U:[GS-01]
        }
    }

    /// @notice Returns the total amount of user's staked GEAR
    function balanceOf(address user) external view returns (uint256) {
        return voteLockData[user].totalStaked;
    }

    /// @notice Returns user's balance available for voting or unstaking
    function availableBalance(address user) external view returns (uint256) {
        return voteLockData[user].available;
    }
}
