pragma solidity ^0.8.17;

import {AggregatorV3Interface} from "src/vendor/AggregatorV3Interface.sol";
import {IERC4626, IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {wdiv, wmul} from "src/utils/Math.sol";


contract AggregatorV3Oracle4626 {
    IERC4626 public immutable vault;
    uint256 public immutable vaultScale;
    uint256 public immutable assetScale;

    constructor(address _vault) {
        vault = IERC4626(_vault);
        vaultScale = 10 ** uint256(vault.decimals());
        assetScale = 10 ** IERC20Metadata(vault.asset()).decimals();
    }


    /// @notice Return the latest price and the current block timestamp
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
      
        uint256 redemptionRate = vault.convertToAssets(vaultScale);
        redemptionRate = wdiv(redemptionRate, assetScale);
        return (0, int256(redemptionRate), 0, block.timestamp, 0);
    }

    function decimals() public pure returns (uint256) {
        return 18;
    }
}
