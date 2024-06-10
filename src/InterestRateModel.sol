// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {WAD, add, wmul, wdiv, wpow} from "./utils/Math.sol";

abstract contract InterestRateModel {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Max. allowed per second base interest rate (200%, assuming 366 days per year) [wad]
    uint64 public constant RATE_CEILING = 1000000021919499726;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Interest Rate State
    struct IRS {
        // Base rate from which the rateAccumulator is derived [wad]
        uint64 baseRate;
        // Last time the interest rate state was updated (up to year 2554) [seconds]
        uint64 lastUpdated;
        // Interest rate accumulator - used for calculating accrued interest [wad]
        uint64 rateAccumulator;
    }
    /// @notice Interest rate state
    IRS private _irs;

    /// @notice Accrued interest
    uint256 private _accruedInterest;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SetBaseRate(int64 baseRate);
    event SetIRS();

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InterestRateModel__setBaseRate_invalidBaseRate();

    /*//////////////////////////////////////////////////////////////
                           GETTER AND SETTERS
    //////////////////////////////////////////////////////////////*/

    function _setBaseRate(uint64 baseRate) internal {
        if (baseRate > RATE_CEILING || baseRate < WAD) {
            revert InterestRateModel__setBaseRate_invalidBaseRate();
        }
        _irs.baseRate = baseRate;
        emit SetBaseRate(int64(baseRate));
    }

    /// @notice Returns the global interest rate state
    /// @return _ Global interest rate state
    function getIRS() public view returns (IRS memory) {
        return _irs;
    }

    /// @notice Sets the global interest rate state
    /// @param irs New global interest rate state
    function _setIRS(IRS memory irs) internal {
        _irs = irs;
        emit SetIRS();
    }

    /// @notice Returns the accrued interest
    /// @return _ Accrued interest
    function getAccruedInterest() public view returns (uint256) {
        return _accruedInterest;
    }

    /// @notice Resets the accrued interest
    function _resetAccruedInterest() internal {
        _accruedInterest = 0;
    }

    /*//////////////////////////////////////////////////////////////
                        INTEREST ACCOUNTING MATH
    //////////////////////////////////////////////////////////////*/

    function _calculateRateAccumulator(IRS memory irs) internal view returns (uint64 rateAccumulator) {
        return uint64(wmul(irs.rateAccumulator, wpow(uint256(irs.baseRate), (block.timestamp - irs.lastUpdated), WAD)));
    }

    /// @notice Calculates the new global interest state
    /// @param totalNormalDebtBefore Previous total normalized debt [wad]
    /// @return irsAfter New global interest rate state
    function _updateIRS(uint256 totalNormalDebtBefore) internal returns (IRS memory irsAfter) {
        IRS memory irsBefore = _irs;

        uint64 rateAccumulatorAfter = _calculateRateAccumulator(irsBefore);

        irsAfter = IRS({
            baseRate: irsBefore.baseRate,
            lastUpdated: uint64(block.timestamp),
            rateAccumulator: rateAccumulatorAfter
        });
        _irs = irsAfter;

        _accruedInterest += (totalNormalDebtBefore == 0)
            ? 0
            : wmul(rateAccumulatorAfter - irsBefore.rateAccumulator, totalNormalDebtBefore);
    }

    /// @notice Returns the virtual rate accumulator
    /// @return rateAccumulator Current virtual rate accumulator [wad]
    function virtualRateAccumulator() public view returns (uint64 rateAccumulator) {
        rateAccumulator = _calculateRateAccumulator(_irs);
    }
}
