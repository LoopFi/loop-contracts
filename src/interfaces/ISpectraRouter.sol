pragma solidity ^0.8.19;

interface ISpectraRouter {
    /**
     * @dev Executes encoded commands along with provided inputs
     * Reverts if deadline has expired
     * @param _commands A set of concatenated commands, each 1 byte in length
     * @param _inputs An array of byte strings containing ABI-encoded inputs for each command
     * @param _deadline The deadline by which the transaction must be executed
     */
    function execute(bytes calldata _commands, bytes[] calldata _inputs, uint256 _deadline) external payable;
}
