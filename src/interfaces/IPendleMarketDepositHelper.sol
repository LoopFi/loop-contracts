// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

interface IPendleMarketDepositHelper {
    function totalStaked(address _market) external view returns (uint256);
    function balance(address _market, address _address) external view returns (uint256);
    function depositMarket(address _market, uint256 _amount) external;
    function depositMarketFor(address _market, address _for, uint256 _amount) external;
    function withdrawMarket(address _market, uint256 _amount) external;
    function withdrawMarketWithClaim(address _market, uint256 _amount, bool _doClaim) external;
    function harvest(address _market) external;
    function setPoolInfo(address poolAddress, address rewarder, bool isActive) external;
    function setOperator(address _address, bool _value) external;
    function setmasterPenpie(address _masterPenpie) external;
    function pendleStaking() external view returns (address);
}
