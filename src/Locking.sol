// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Locking is Ownable {
    using SafeERC20 for IERC20;

    uint256 public cooldownPeriod;
    IERC20 public token;

    struct Deposit {
        uint256 amount;
        uint256 cooldownStart;
        uint256 cooldownAmount;
    }

    mapping(address => Deposit) public deposits;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event CooldownPeriodSet(uint256 cooldownPeriod);
    event CooldownInitiated(address indexed user, uint256 timestamp, uint256 amount);

    constructor(address _token) {
        token = IERC20(_token);
    }

    function setCooldownPeriod(uint256 _cooldownPeriod) external onlyOwner {
        cooldownPeriod = _cooldownPeriod;
        emit CooldownPeriodSet(_cooldownPeriod);
    }

    function deposit(uint256 _amount) external {
        require(_amount > 0, "Must send some tokens to deposit");

        deposits[msg.sender].amount += _amount;
        token.safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposited(msg.sender, _amount);
    }

    function initiateCooldown(uint256 _amount) external {
        require(deposits[msg.sender].amount >= _amount, "Insufficient balance to set cooldown amount");
        deposits[msg.sender].cooldownStart = block.timestamp;
        deposits[msg.sender].cooldownAmount = _amount;

        emit CooldownInitiated(msg.sender, block.timestamp, _amount);
    }

    function withdraw() external {
        uint256 _amount;
        if (cooldownPeriod > 0) {
            require(deposits[msg.sender].cooldownAmount > 0, "No tokens in cooldown");
            require(
                block.timestamp >= deposits[msg.sender].cooldownStart + cooldownPeriod,
                "Cooldown period has not passed"
            );
            _amount = deposits[msg.sender].cooldownAmount;
        } else {
            _amount = deposits[msg.sender].amount;
        }

        deposits[msg.sender].amount -= _amount;
        deposits[msg.sender].cooldownAmount = 0;
        deposits[msg.sender].cooldownStart = 0;
        token.safeTransfer(msg.sender, _amount);

        emit Withdrawn(msg.sender, _amount);
    }

    function getBalance(address _user) external view returns (uint256) {
        return deposits[_user].amount;
    }

    function getCoolDownInfo(address _user) external view returns (uint256, uint256, uint256) {
        return (deposits[_user].amount, deposits[_user].cooldownStart, deposits[_user].cooldownAmount);
    }
}
