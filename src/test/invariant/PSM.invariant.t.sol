// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantTestBase} from "./InvariantTestBase.sol";
import {GhostVariableStorage} from "./handlers/BaseHandler.sol";
import {PSMHandler} from "./handlers/PSMHandler.sol";
import {StablecoinHandler} from "./handlers/StablecoinHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";

import {PSM} from "../../PSM.sol";
import {IMinter} from "../../interfaces/IMinter.sol";
import {ICDM} from "../../interfaces/ICDM.sol";

/// @title PSMInvariantTest
/// @notice PSM invariant tests 
contract PSMInvariantTest is InvariantTestBase{

    PSMHandler internal psmHandler;
    PSM internal psm;
    MockERC20 internal mockCollateral;

    /// ======== Setup ======== ///
    function setUp() public override virtual{
        super.setUp();

        mockCollateral = new MockERC20();
        GhostVariableStorage ghostVariableStorage = new GhostVariableStorage();

        mockCollateral.initialize("MockERC20", "MOCK", 18);

        psm = new PSM( {
            minter_: IMinter(minter),
            cdm_: ICDM(cdm),
            stablecoin_: IERC20(address(stablecoin)),
            collateral_: IERC20(address(mockCollateral)),
            roleAdmin: address(this),
            configAdmin: address(this),
            pauseAdmin: address(this)
        });
        cdm.setParameter(address(psm), "debtCeiling", 5_000_000_000 ether);
        
        psmHandler = new PSMHandler(
            address(psm), 
            this, 
            address(stablecoin), 
            address(mockCollateral), 
            ghostVariableStorage
        );

        // setup stablecoin handler selectors
        bytes4[] memory psmHandlerSelectors = new bytes4[](2);
        psmHandlerSelectors[0] = PSMHandler.mint.selector;
        psmHandlerSelectors[1] = PSMHandler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(psmHandler), selectors: psmHandlerSelectors}));

        // label the handlers
        vm.label({ account: address(psmHandler), newLabel: "PSMHandler" });
        targetContract(address(psmHandler));
    }

    /// ======== CDM Invariant Tests ======== ///
    
    function invariant_PSM_A() external useCurrentTimestamp printReport(psmHandler) {
         uint256 collateralBalance = mockCollateral.balanceOf(address(psm));
        assert_invariant_PSM_A(collateralBalance);
    }
}