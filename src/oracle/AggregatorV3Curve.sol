pragma solidity ^0.8.17;

interface ICurvePool { 
    function price_oracle(uint256 k) external view returns (uint256); 
}

contract AggregatorV3Curve {
    ICurvePool public immutable pool;
    uint256 public immutable k;
    bool public immutable invert;

    constructor(address _pool, uint256 _k, bool _invert) {
        pool = ICurvePool(_pool);
        k = _k;
        invert = _invert;
    }


    /// @notice Return the latest redemption rate in stETH for 1 wstETH and the current block timestamp
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price = pool.price_oracle(k);
        price = invert ? 1e36 / price : price;
        return (0, int256(price), 0, block.timestamp, 0);
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
