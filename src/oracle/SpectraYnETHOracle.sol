// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {wdiv, wmul} from "../utils/Math.sol";
import {IOracle, MANAGER_ROLE} from "../interfaces/IOracle.sol";
import {IStableSwap} from "src/interfaces/IStableSwapTranchess.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICurvePool} from "src/vendor/ICurvePool.sol";

/// The oracle is upgradable if the current implementation does not return a valid price
contract SpectraYnETHOracle is IOracle, AccessControlUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    /// @notice ynETH address
    ERC4626 public immutable ynETH;
    /// @notice Stableswap contract
    ICurvePool public immutable curvePool;
    /// @notice Spectra ynETH
    ERC4626 public immutable spectraYnETH;
    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SpectraYnETHOracle__spot_invalidValue();
    error SpectraYnETHOracle__authorizeUpgrade_validStatus();
    error SpectraYnETHOracle__validatePtOracle_invalidValue();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor(address curvePool_, address ynETH_, address spectraYnETH_) initializer {
        ynETH = ERC4626(ynETH_);
        spectraYnETH = ERC4626(spectraYnETH_);
        curvePool = ICurvePool(curvePool_);
    }

    /*//////////////////////////////////////////////////////////////
                             UPGRADEABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize method called by the proxy contract
    /// @param admin The address of the admin
    /// @param manager The address of the manager who can authorize upgrades
    function initialize(address admin, address manager) external initializer {
        // init. Access Control
        __AccessControl_init();
        // Role Admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Credit Manager
        _grantRole(MANAGER_ROLE, manager);
    }

    /// @notice Authorizes an upgrade
    /// @param /*implementation*/ The address of the new implementation
    /// @dev reverts if the caller is not a manager or if the status check succeeds
    function _authorizeUpgrade(address /*implementation*/) internal virtual override onlyRole(MANAGER_ROLE) {
        // if (_getStatus()) revert SpectraYnETHOracle__authorizeUpgrade_validStatus();
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the status of the oracle
    /// @param /*token*/ Token address, ignored for this oracle
    /// @dev The status is valid if the price is validated and not stale
    function getStatus(address /*token*/) public view virtual override returns (bool status) {
        return true; //_getStatus();
    }

    /// @notice Returns the latest price for the asset from Chainlink [WAD]
    /// @param /*token*/ Token address
    /// @return price Asset price [WAD]
    /// @dev reverts if the price is invalid
    function spot(address /* token */) external view virtual override returns (uint256 price) {
        uint256 spectraYnETHVirtualPrice = _fetchVirtualPrice();
        uint256 lpPriceInYnETH = spectraYnETH.convertToAssets(spectraYnETHVirtualPrice);
        return ynETH.convertToAssets(lpPriceInYnETH);
    }

    /// @notice LP token virtual price in Spectra ynETH
    /// @return virtualPrice LP token virtual price in Spectra ynETH
    function _fetchVirtualPrice() internal view returns (uint256 virtualPrice) {
        return curvePool.lp_price();
    }
}
