// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ICDPVault_Deployer} from "../../interfaces/ICDPVault_Deployer.sol";
import {CDPVaultConstants, CDPVaultConfig} from "../../interfaces/ICDPVault.sol";

import {wmul, wdiv, min, add, mul} from "../../utils/Math.sol";

import {CDM} from "../../CDM.sol";
import {calculateDebt, calculateNormalDebt} from "../../CDPVault.sol";
import {CDPVault} from "../../CDPVault.sol";

contract CDPVaultWrapper is CDPVault {
    
    constructor(
        CDPVaultConstants memory constants,
        CDPVaultConfig memory config
    ) CDPVault(constants, config) {}

    function getMaximumDebtForCollateral(
        address owner, address collateralizer, address creditor, int256 deltaCollateral_
    ) public view returns (int256 deltaCollateral, int256 deltaNormalDebt, uint256 creditNeeded) {
        Position memory position = positions[owner];

        deltaCollateral = deltaCollateral_;

        if (deltaCollateral < 0) deltaCollateral = _max(deltaCollateral, -int256(position.collateral));
        else deltaCollateral = _min(deltaCollateral, int256(cash[collateralizer]));

        uint256 positionDebtCeiling = wmul(
            add(position.collateral, deltaCollateral), 
            // apply a 10% buffer to the liquidation price to avoid liquidation due to precision error
            wmul(liquidationPrice(), uint256(0.9 ether))
        );

        uint64 rateAccumulator = virtualRateAccumulator();
        uint256 debt = calculateDebt(position.normalDebt, rateAccumulator);
        int256 debtCapacity;

        // avoid stack too deep
        {
        debtCapacity = min(
            int256(min(cdm.creditLine(address(this)), cdm.globalDebtCeiling() - cdm.globalDebt())), 
            int256(positionDebtCeiling) - int256(debt)
        );
        
        uint256 absoluteDebtCapacity = uint256(debtCapacity < 0 ? -debtCapacity : debtCapacity);
        deltaNormalDebt = int256(calculateNormalDebt(absoluteDebtCapacity, rateAccumulator));
        
        if(debtCapacity < 0) deltaNormalDebt = -deltaNormalDebt;
        }

        int256 deltaDebt = wmul(rateAccumulator, deltaNormalDebt);
        int256 creditLine = int256(cdm.creditLine(creditor));
        creditNeeded = (deltaDebt > 0 || creditLine > -deltaDebt) ? uint256(0) : uint256(-deltaDebt - creditLine);

        int256 newPositionDebt = int256(position.normalDebt) + deltaNormalDebt;

        // if we are below the debt floor cancel the deltaDebt
        if(newPositionDebt > 0 && newPositionDebt < int256(int128(vaultConfig.debtFloor))){
            deltaNormalDebt = 0;
            deltaCollateral = 0;
            creditNeeded = 0;
        }
        return (deltaCollateral, deltaNormalDebt, creditNeeded);
    }

    function liquidationPrice() view internal returns (uint256) {
       return wdiv(spotPrice(), uint256(vaultConfig.liquidationRatio));
    }

    function _max(int256 a, int256 b) private pure returns (int256) {
        if(a > b) return a;
        return b;
    }

    function _min(int256 a, int256 b) private pure returns (int256) {
        if(a < b) return a;
        return b;   
    }
}