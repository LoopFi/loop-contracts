// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IPoolV3, IPoolV3Events} from "../vendor/IPoolV3.sol";

interface ICDPCreditVaultEvents is IPoolV3Events {
	/// @notice Emitter when redeeming Underlying tokens for internal credit
	event Enter(address indexed user, uint256 amount);

	/// @notice Emitter when redeeming internal credit for Underlying tokens
    event Exit(address indexed user, uint256 amount);
}

interface ICDPCreditVault is IPoolV3, ICDPCreditVaultEvents {
	function cdm() external view returns (address);

	function enter(address user, uint256 amount) external;
	function exit(address user, uint256 amount) external;
}