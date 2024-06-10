// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMinter} from "./interfaces/IMinter.sol";
import {ICDM} from "./interfaces/ICDM.sol";
import {Pause, PAUSER_ROLE} from "./utils/Pause.sol";
import {wmul} from "./utils/Math.sol";

bytes32 constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

contract PSM is AccessControl, Pause {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minter contract
    IMinter public immutable minter;

    /// @notice Credit-Debt Manager contract
    ICDM public immutable cdm;

    /// @notice Stablecoin token
    IERC20 public immutable stablecoin;

    /// @notice Collateral token
    IERC20 public immutable collateral;

    /// @notice Collateral conversion factor based on its decimals
    uint256 public immutable collateralConversionFactor;

    /// @notice The fee charged for minting stablecoin [wad]
    uint256 public mintFee;

    /// @notice The fee charged for redeeming stablecoin [wad]
    uint256 public redeemFee;

    /// @notice Total collected fees in collateral units
    uint256 public collectedFees;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed user, uint256 amount, uint256 fee);
    event Redeem(address indexed user, uint256 amount, uint256 fee);
    event SetParameter(bytes32 indexed parameter, uint256 data);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PSM__constructor_unsupportedCollateral();
    error PSM__setParameter_unrecognizedParameter();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the contract with given parameters
    /// @param minter_ The stablecoin minter contract
    /// @param cdm_ The credit-debt manager contract
    /// @param collateral_ The collateral token contract
    /// @param roleAdmin The admin role address
    /// @param configAdmin The configuration admin role address
    /// @param pauseAdmin The pause admin role address
    constructor(
        IMinter minter_,
        ICDM cdm_,
        IERC20 collateral_,
        IERC20 stablecoin_,
        address roleAdmin,
        address configAdmin,
        address pauseAdmin
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, roleAdmin);
        _grantRole(CONFIG_ROLE, configAdmin);
        _grantRole(PAUSER_ROLE, pauseAdmin);

        minter = minter_;
        cdm = cdm_;
        collateral = collateral_;
        stablecoin = stablecoin_;

        cdm.modifyPermission(address(minter_), true);
        stablecoin.approve(address(minter_), type(uint256).max);

        uint256 decimals = IERC20Metadata(address(collateral_)).decimals();
        uint256 conversionFactor;
        if (decimals > 18) revert PSM__constructor_unsupportedCollateral();
        else conversionFactor = 10 ** (18 - decimals);

        collateralConversionFactor = conversionFactor;
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param parameter Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParameter(bytes32 parameter, uint256 data) external onlyRole(CONFIG_ROLE) {
        if (parameter == "mintFee") {
            mintFee = data;
        } else if (parameter == "redeemFee") {
            redeemFee = data;
        } else revert PSM__setParameter_unrecognizedParameter();
        emit SetParameter(parameter, data);
    }

    /*//////////////////////////////////////////////////////////////
                             MINTING AND BURNING
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints stablecoin in exchange for collateral with a fee
    /// @param amount The amount of stablecoin to mint [wad]
    /// @dev User must have set allowance for PSM to transfer collateral
    function mint(uint256 amount) external whenNotPaused {
        // Calculate the fee in stablecoin units and collateral units
        uint256 feeInStablecoin = wmul(amount, mintFee);
        uint256 totalCollateralAmount = amount / collateralConversionFactor;
        uint256 feeInCollateral = feeInStablecoin / collateralConversionFactor;
        collectedFees += feeInCollateral;

        collateral.safeTransferFrom(msg.sender, address(this), totalCollateralAmount);

        uint256 netMintAmount = amount - feeInStablecoin;
        minter.exit(msg.sender, netMintAmount);

        emit Mint(msg.sender, netMintAmount, feeInCollateral);
    }

    /// @notice Redeems stablecoin in exchange for collateral with a fee
    /// @param amount The amount of stablecoin to redeem [wad]
    function redeem(uint256 amount) external whenNotPaused {
        // Calculate the fee in stablecoin units
        uint256 feeInStablecoin = wmul(amount, redeemFee);
        // Convert the stablecoin amount and fee to collateral units
        uint256 amountInCollateral = amount / collateralConversionFactor;
        uint256 feeInCollateral = feeInStablecoin / collateralConversionFactor;
        collectedFees += feeInCollateral;

        // Burn the stablecoins from the user
        stablecoin.transferFrom(msg.sender, address(this), amount);
        minter.enter(address(this), amount);
        // Transfer the collateral to the user, subtracting the fee
        collateral.safeTransfer(msg.sender, amountInCollateral - feeInCollateral);

        emit Redeem(msg.sender, amountInCollateral - feeInCollateral, feeInCollateral);
    }

    /// @notice Collects accumulated fees to a specified receiver
    /// @param receiver The address to receive the collected fees
    function collectFees(address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 amount = collectedFees;
        collectedFees = 0;
        collateral.safeTransfer(receiver, amount);
    }
}
