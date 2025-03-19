pragma solidity ^0.8.17;

import {AggregatorV3Interface} from "src/vendor/AggregatorV3Interface.sol";
import {IERC4626, IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {wdiv, wmul} from "src/utils/Math.sol";

/// @title Combined4626AggregatorV3Oracle
/// @notice This contract combines an AggregatorV3 oracle with an ERC4626 vault to provide a single price feed (ex. wstUSR/USD from USR/USD and wstUSR/USR vault)
contract Combined4626AggregatorV3Oracle {
    error Combined4626AggregatorV3Oracle__invalidAggregatorValue();

    AggregatorV3Interface public immutable aggregator;
    uint256 public immutable aggregatorHeartbeat;
    uint256 public immutable aggregatorScale;
    IERC4626 public immutable vault;
    uint256 public immutable vaultScale;
    uint256 public immutable assetScale;

    constructor(address _aggregator, uint256 _aggregatorHeartbeat, address _vault) {
        aggregator = AggregatorV3Interface(_aggregator);
        aggregatorScale = 10 ** uint256(aggregator.decimals());
        aggregatorHeartbeat = _aggregatorHeartbeat;

        vault = IERC4626(_vault);
        vaultScale = 10 ** uint256(vault.decimals());
        assetScale = 10 ** IERC20Metadata(vault.asset()).decimals();
    }

    function getAggregatorData() public view returns (uint256, uint256) {
        (, int256 answer, , uint256 updatedAt, ) = aggregator.latestRoundData();
        bool isValid = (answer > 0 && block.timestamp - updatedAt <= aggregatorHeartbeat);
        if (!isValid) revert Combined4626AggregatorV3Oracle__invalidAggregatorValue();
        return (wdiv(uint256(answer), aggregatorScale), uint256(updatedAt));
    }

    /// @notice Return the latest price and the timestamp from the AggregatorV3 oracle
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint256 value, uint256 timestamp) = getAggregatorData();
        uint256 redemptionRate = vault.convertToAssets(vaultScale);
        redemptionRate = wdiv(redemptionRate, assetScale);
        value = wmul(redemptionRate, value);
        return (0, int256(value), 0, timestamp, 0);
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
