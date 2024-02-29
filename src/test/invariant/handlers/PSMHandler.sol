// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./BaseHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PSM} from "../../../PSM.sol";

contract PSMHandler is BaseHandler {
    PSM public psm;

    address public collateral;
    address public stablecoin;

    uint256 public mintAccumulator;
    uint256 public burnAccumulator;
    uint256 public collateralAccumulator;

    uint256 public immutable maximumMint = 10_000_000 ether;

    constructor(address psm_, InvariantTestBase testContract_, address stablecoin_, address collateral_, GhostVariableStorage ghostStorage_) BaseHandler("CDMHandler", testContract_, ghostStorage_) {
        psm = PSM(psm_);
        collateral = collateral_;
        stablecoin = stablecoin_;
    }

    function getTargetSelectors() public pure virtual override returns(bytes4[] memory selectors, string[] memory names) {
        selectors = new bytes4[](2);
        names = new string[](2);
        
        selectors[0] = this.mint.selector;
        names[0] = "mint";

        selectors[1] = this.redeem.selector;
        names[1] = "redeem";
    }

    function mint(address user, uint256 stablecoinAmount) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        if (user == address(0)) return;

        addActor(USERS_CATEGORY, user);

        stablecoinAmount = bound(stablecoinAmount, 100 ether, maximumMint);
        uint256 collateralAmount = stablecoinAmount;

        deal(collateral, user, collateralAmount);

        vm.startPrank(user);
        IERC20(collateral).approve(address(psm), collateralAmount);

        mintAccumulator += stablecoinAmount;
        psm.mint(stablecoinAmount);

        vm.stopPrank();

        trackCallEnd(msg.sig);
    }

    function redeem(uint256 userSeed, uint256 redeemAmountSeed) public useCurrentTimestamp {
        trackCallStart(msg.sig);

        address user = getRandomActor(USERS_CATEGORY, userSeed);
        if(user == address(0)) return;

        uint256 redeemAmount = bound(redeemAmountSeed, 0, IERC20(stablecoin).balanceOf(address(user)));
        vm.startPrank(user);
        IERC20(stablecoin).approve(address(psm), redeemAmount);

        burnAccumulator += redeemAmount;
        psm.redeem(redeemAmount);

        vm.stopPrank();

        trackCallEnd(msg.sig);
    }
}
