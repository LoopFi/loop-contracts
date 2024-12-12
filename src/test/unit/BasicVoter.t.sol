// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {BasicVoter, CONFIGURATOR} from "src/quotas/BasicVoter.sol";

contract BasicVoterTest is Test {
    BasicVoter voter;

    function setUp() public {
        voter = new BasicVoter(block.timestamp, 7 days);
    }

    function test_deploy() public {
        assertNotEq(address(voter), address(0));
    }

    function test_setEpochParams() public {
        voter.setEpochParams(block.timestamp, 1 days);
    }

    function test_setEpochParams_timestampInPast() public {
        voter.setEpochParams(block.timestamp - 1, 1 days);
    }

    function test_setEpochParams_revertsIfNotAuthorized() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        voter.setEpochParams(block.timestamp, 1 days);

        voter.grantRole(CONFIGURATOR, address(0x1234));
        voter.setEpochParams(block.timestamp, 1 days);
    }

    function test_setEpochParams_lengthZero() public {
        vm.expectRevert(BasicVoter.EpochParams__setEpochParams_lengthZero.selector);
        voter.setEpochParams(block.timestamp, 0);
    }

    function test_getCurrentEpoch() public {
        uint16 expectedValue = uint16((block.timestamp - voter.firstEpochTimestamp()) / voter.epochLength()) + 1;
        assertEq(voter.getCurrentEpoch(), expectedValue);

        vm.warp(block.timestamp + 3 days);

        expectedValue = uint16((block.timestamp - voter.firstEpochTimestamp()) / voter.epochLength())+ 1;
        assertEq(voter.getCurrentEpoch(), expectedValue);
    }
}
