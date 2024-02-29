// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {WAD, wmul, wpow, wdiv, add} from "../../utils/Math.sol";
import {InterestRateModel} from "../../InterestRateModel.sol";

contract InterestRateModelWrapper is InterestRateModel, Test {

    constructor(uint64 baseRate) {
        _setIRS(IRS(baseRate, uint64(block.timestamp), uint64(WAD)));
    }

    function setIRS(IRS memory irs) public {
        return _setIRS(irs);
    }

    function setBaseRate(uint64 baseRate) public {
        return _setBaseRate(baseRate);
    }

    function calculateRateAccumulator(IRS memory irs_) public view returns (uint64) {
        return _calculateRateAccumulator(irs_);   
    }

    function calculateIRS(
        uint256 totalNormalDebtBefore
    ) public returns(
        IRS memory irsAfter
    ){
        irsAfter = _updateIRS(
            totalNormalDebtBefore
        );
    }
}

contract InterestRateModelTest is Test {
    InterestRateModelWrapper internal model;

    address internal user1 = address(1);
    address internal user2 = address(2);
    address internal user3 = address(3);

    uint64 internal rateCeiling = 1000000021919499726;

    struct CalculateParams{
        // inputs
        InterestRateModel.IRS irsBefore;
        uint64 rateAccumulatorAfter;
        uint256 totalNormalDebtBefore;

        // outputs to validate
        InterestRateModel.IRS irsAfter;
        uint256 accruedInterest;
    }

    function setUp() public {
        // 1% baseRate
        model = new InterestRateModelWrapper(1000000000314660837);
    }

    /*//////////////////////////////////////////////////////////////
                            TEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_setBaseRate(uint64 baseRate) public {
        baseRate = uint64(bound(uint256(baseRate), uint256(WAD), rateCeiling));
        model.setBaseRate(baseRate);
        InterestRateModel.IRS memory irs = model.getIRS();
        assertEq(irs.baseRate, baseRate);
    }

    function test_setBaseRate_revertOnInvalidValues() public {
        uint64 invalidRate = uint64(1);
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);

        invalidRate = uint64(WAD - 1);
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);

        invalidRate = uint64(1000000021919499726 + 1);
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);

        invalidRate = type(uint64).max;
        vm.expectRevert(InterestRateModel.InterestRateModel__setBaseRate_invalidBaseRate.selector);
        model.setBaseRate(invalidRate);
    }

    function test_calculateRateAccumulatorFuzz(uint64 rateAccumulator, uint64 baseRate, uint64 timeStamp, uint64 updateSeed) public {
        InterestRateModel.IRS memory irs = model.getIRS();
        // bound the warp to max 2 years
        timeStamp = uint64(bound(timeStamp, 0, 86400 * 366 * 2));
        irs.lastUpdated = uint64(bound(updateSeed, 0, timeStamp));
        irs.rateAccumulator = uint64(
            bound(
                rateAccumulator, 
                WAD, 
                wdiv(type(uint64).max, wpow(uint64(rateCeiling),86400 * 366 * 2, WAD))
            )
        );
        irs.baseRate = uint64(bound(baseRate, WAD, uint64(rateCeiling)));

        vm.warp(timeStamp);
        uint64 expectedValue = uint64(wmul(
            irs.rateAccumulator,
            wpow(uint256(irs.baseRate), (block.timestamp - irs.lastUpdated), WAD)
        ));

        assertEq(expectedValue, model.calculateRateAccumulator(irs));
    }

    function test_calculateRateAccumulator() public {
        vm.warp(366 days);
        // Interest Rate = 0%
        assertEq(model.calculateRateAccumulator(InterestRateModel.IRS(uint64(WAD), 0, uint64(WAD))), uint64(WAD));

        // Interest Rate = 1%
        assertEq(
            model.calculateRateAccumulator(InterestRateModel.IRS(uint64(1000000000314660837), 0, uint64(WAD))), 
            uint64(wmul(WAD, wpow(1000000000314660837, 366 * 86400, WAD)))
        );
        
        // Interest Rate = 100%
        vm.warp(366 days * 18);
        assertEq(
            model.calculateRateAccumulator(InterestRateModel.IRS(uint64(1000000021919499726), 0, uint64(WAD))), 
            uint64(wmul(WAD, wpow(1000000021919499726, 366 * 18 * 86400, WAD)))
        );
    }
}