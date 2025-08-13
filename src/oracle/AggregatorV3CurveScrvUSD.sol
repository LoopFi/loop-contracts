pragma solidity ^0.8.17;

interface ICurvePool { 
    function price_oracle(uint256 k) external view returns (uint256); 
}

interface ISCRVUSDOracle {
    function price_v0() external view returns (uint256);
}

/**
 * @title AggregatorV3CurveScrvUSD
 * @notice Uses curve scrvUSD oracle for getting the exchange rate scrvUSD/crvUSD
 */
contract AggregatorV3CurveScrvUSD {
    ICurvePool public immutable pool;
    uint256 public immutable k;
    bool public immutable invert;
    ISCRVUSDOracle public immutable scrvUSDOracle;

    constructor(address _pool, uint256 _k, bool _invert, address _scrvUSDOracle) {
        pool = ICurvePool(_pool);
        k = _k;
        invert = _invert;
        scrvUSDOracle = ISCRVUSDOracle(_scrvUSDOracle);
    }


    /// @notice Return the latest redemption rate in stETH for 1 wstETH and the current block timestamp
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price = pool.price_oracle(k);
        price = invert ? 1e36 / price : price;
        uint256 scrvUSDRate = scrvUSDOracle.price_v0();
        price = (price * scrvUSDRate) / 1e18;
        return (0, int256(price), 0, block.timestamp, 0);
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
