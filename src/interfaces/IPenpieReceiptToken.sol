// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

interface IPenpieReceiptToken {
    function underlying() external view returns (address);
}