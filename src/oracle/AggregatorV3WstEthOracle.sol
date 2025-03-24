pragma solidity ^0.8.17;

interface IWstEth { 
    // Amount of stETH for 1 wstETH
    function stEthPerToken() external view returns (uint256); 
    function decimals() external view returns (uint256);
}
contract AggregatorV3WstEthOracle {
    IWstEth public immutable wstEth;

    constructor(address _wstEth) {
        wstEth = IWstEth(_wstEth);
    }


    /// @notice Return the latest redemption rate in stETH for 1 wstETH and the current block timestamp
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 redemptionRate = wstEth.stEthPerToken();
        return (0, int256(redemptionRate), 0, block.timestamp, 0);
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
