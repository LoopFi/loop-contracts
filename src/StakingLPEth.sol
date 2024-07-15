pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract StakingLPEth is ERC4626 {
    constructor(
        address _liquidityPool,
        string memory _name,
        string memory _symbol
    ) ERC4626(IERC20(_liquidityPool)) ERC20(_name, _symbol) {}
}
