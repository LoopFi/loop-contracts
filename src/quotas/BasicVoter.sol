// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

bytes32 constant CONFIGURATOR = keccak256("BASIC_VOTER_CONFIGURATOR");


contract BasicVoter is AccessControl {

    uint256 public epochLength;
    uint256 public firstEpochTimestamp;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error EpochParams__setEpochParams_lengthZero();

    constructor(uint256 _firstEpochTimestamp, uint256 _epochLength) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONFIGURATOR, msg.sender);
        _setEpochParams(_firstEpochTimestamp, _epochLength);
    }

    /// @notice Sets the epoch parameters
    /// @param timestamp The timestamp of the first epoch
    /// @param length The length of the epoch in seconds
    function setEpochParams(uint256 timestamp, uint256 length) onlyRole(CONFIGURATOR) external {
        _setEpochParams(timestamp, length);
    }

    /// @dev Internal function to set the epoch parameters
    /// @param timestamp The timestamp of the first epoch
    /// @param length The length of the epoch in seconds
    function _setEpochParams(uint256 timestamp, uint256 length) internal {
        if (length == 0) revert EpochParams__setEpochParams_lengthZero();
        firstEpochTimestamp = timestamp;
        epochLength = length;
    }

    /// @notice Returns the current global voting epoch
    function getCurrentEpoch() public view returns (uint16) {
        if (block.timestamp < firstEpochTimestamp) return 0; // U:[GS-01]
        unchecked {
            return uint16((block.timestamp - firstEpochTimestamp) / epochLength) + 1; // U:[GS-01]
        }
    }
}
