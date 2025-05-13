# CDPVault Documentation

## Overview

The CDPVault is a Collateralized Debt Position (CDP) system that allows users to borrow assets against their collateral. The system integrates with Gearbox's PoolV3 for liquidity management and uses robust oracles for collateral pricing.

## Key Components

### 1. Collateral Management
- The vault accepts various collateral tokens
- Collateral prices are determined by robust oracles
- Collateralization ratio is enforced to maintain system safety

### 2. Liquidity Integration
- Integrates with Gearbox's PoolV3 for liquidity management
- PoolV3 manages interest rates based on utilization
- Both contracts have been extensively audited

## Borrow Flow

### Prerequisites
1. User must have sufficient collateral deposited
2. Position must meet minimum collateralization requirements
3. Vault must have available liquidity from PoolV3

### Process
1. **Collateral Verification**
   - System checks collateral value using oracle prices
   - Verifies position meets minimum collateralization ratio
   - Ensures vault has sufficient liquidity

2. **Borrow Execution**
   - User specifies borrow amount
   - System calculates scaled borrow amount based on pool's underlying scale
   - Position's debt is increased by the borrow amount
   - Underlying tokens are transferred to the borrower

3. **Interest Rate Application**
   - PoolV3's utilization-based interest rate is applied
   - Interest accrues on the borrowed amount
   - Rate updates based on pool utilization

## Repay Flow

### Prerequisites
1. User must have sufficient underlying tokens to repay
2. Position must have outstanding debt
3. User must approve vault to spend underlying tokens

### Process
1. **Repayment Calculation**
   - System calculates total debt including accrued interest
   - Determines repayment amount based on user input
   - Applies repayment to debt components in order:
     1. Quota update fees
     2. Quota interest
     3. Base interest
     4. Debt principal

2. **Repayment Execution**
   - User transfers underlying tokens to vault
   - System updates position's debt balance
   - Updates interest indices and quota parameters
   - Transfers repaid amount to PoolV3

3. **Interest Settlement**
   - Accrued interest is settled
   - New interest index is calculated
   - Position's cumulative quota interest is updated

## Safety Features

### 1. Collateralization Checks
- Minimum collateralization ratio enforcement
- Real-time price updates from oracles
- Liquidation mechanism for undercollateralized positions

### 2. Interest Rate Management
- Dynamic interest rates based on pool utilization
- Separate tracking of base interest and quota interest
- Transparent interest accrual and settlement

### 3. Access Control
- Pausable functionality for emergency situations
- Role-based access control for administrative functions

## Integration with PoolV3

### 1. Liquidity Management
- PoolV3 provides underlying token liquidity
- Interest rates are determined by pool utilization
- Seamless integration for borrow and repay operations

### 2. Interest Rate Model
- Utilization-based interest rate calculation
- Separate tracking of base and quota interest
- Dynamic rate adjustments based on market conditions

## Security Considerations

1. **Audits**
   - Both CDPVault and PoolV3 contracts have been extensively audited
   - Gearbox contracts are market-tested and audited
   - Regular security reviews and updates
   - Code arena contests: 
      - https://code4rena.com/reports/2024-07-loopfi
      - https://code4rena.com/reports/2024-07-loopfi
   - Watchpug audits:
      - https://notes.watchpug.com/p/1956031b374KRSUi
      - https://notes.watchpug.com/p/195172e920dMC94

2. **Risk Management**
   - Collateralization ratio enforcement
   - Liquidation mechanism for unsafe positions
   - Emergency pause functionality

3. **Oracle Security**
   - Robust price feed integration
   - Multiple oracle support
   - Price deviation checks