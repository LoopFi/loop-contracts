const { ethers } = require('hardhat');
const toWad = ethers.utils.parseEther;

module.exports = {
  "Core": {
    "Flashlender": {
      "constructorArguments": {
        "protocolFee_": toWad('0')
      },
      "initialDebtCeiling": toWad('100000000'),
    },
    "WXDC": "0x951857744785E80e2De051c32EE7b25f9c458C42", // XDC native token wrapped
    "USDC": "0xcc0587aebda397146cc828b445db130a94486e74", // USDC on XDC
    "WETH": "0xa7348290de5cf01772479c48D50dec791c3fC212", // WETH on XDC
    "AddressProviderV3": "0xE67f77af54EdA6B92f2dBaB272b8C0817ae0bCa3",
    "PoolV3_LpXDC": "0xED166436559Fd3d7f44cb00CACDA96EB999D789e", // To be filled after deployment
    "PoolV3_LpUSDC": "", // To be filled after deployment
    "FlashlenderLPXDC": "", // To be filled after deployment
    "FlashlenderLPUSDC": "", // To be filled after deployment
    "VaultRegistry": "", // To be filled after deployment
    "ProxyRegistry": "", // To be filled after deployment
    "PoolQuotaKeeperV3": "", // To be filled after deployment
    "GaugeV3": "", // To be filled after deployment
    "Actions": {
      "SwapAction": {
        "constructorArguments": {
          "balancerVault": "", // To be filled with XDC Balancer Vault
          "uniV3Router": "", // To be filled with XDC Uniswap V3 Router
          "pendleRouter": "", // To be filled with XDC Pendle Router
          "kyberRouter": "", // To be filled with XDC Kyber Router
          "tranchessRouter": "", // To be filled with XDC Tranchess Router
          "spectraRouter": "" // To be filled with XDC Spectra Router
        }
      },
      "PoolAction": {
        "constructorArguments": {
          "balancerVault": "", // To be filled with XDC Balancer Vault
          "pendleRouter": "", // To be filled with XDC Pendle Router
          "tranchessRouter": "", // To be filled with XDC Tranchess Router
          "spectraRouter": "" // To be filled with XDC Spectra Router
        }
      },
    },
    "Gearbox": {
      "initialGlobalDebtCeiling": "115792089237316195423570985008687907853269984665640564039457584007913129639935", // max uint256
    },
    "Treasury": {
      "constructorArguments": {
        "payees":[
          "0xA719A90a173E8F00618596ffb594F5FfA79d915D",
          "stakingLpXDC"
        ],
        "shares":[
          200,
          800
        ],
        "admin": "deployer"
      }
    },
  },
  "Pools": {
    "Pool LpUSDC": {
      "name": "Loop Liquidity Pool - USDC.e",
      "symbol": "lpUSDCe",
      "wrappedToken": "0x0000000000000000000000000000000000000000", //
      "treasury": "", // To be filled with actual treasury address
      "underlier": "0xcc0587aebda397146cc828b445db130a94486e74", // USDC.E
      "interestRateModel": {
        "U_1": 8000, // U_1 - Higher utilization target for stablecoin
        "U_2": 9500, // U_2 - Higher optimal utilization for stablecoin
        "R_base": 0, // R_base
        "R_slope1": 1000, // R_slope1 - Lower slope for stablecoin
        "R_slope2": 2000, // R_slope2 - Moderate slope
        "R_slope3": 50000, // R_slope3 - High penalty slope
      }, 
    }
  },
  "Vendors": {
  },
  "Vaults": {
  },
 
  "Tokenomics":{
  }
}; 