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
    "AddressProviderV3": "0xE67f77af54EdA6B92f2dBaB272b8C0817ae0bCa3",
    "PoolV3_LpXDC": "", // To be filled after deployment
    "FlashlenderLPXDC": "", // To be filled after deployment
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
    "Pool LpXDC": {
      "name": "Loop Liquidity Pool - XDC",
      "symbol": "lpXDC",
    //   "poolAddress": "", // To be filled after deployment
      "wrappedToken": "0x951857744785E80e2De051c32EE7b25f9c458C42", // WXDC
      "treasury": "", // To be filled with actual treasury address
      "underlier": "0x951857744785E80e2De051c32EE7b25f9c458C42", // WXDC
      "interestRateModel": {
        "U_1": 7000, // U_1
        "U_2": 9000, // U_2
        "R_base": 0, // R_base
        "R_slope1": 2000, // R_slope1
        "R_slope2": 2500, // R_slope2
        "R_slope3": 60000, // R_slope3
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