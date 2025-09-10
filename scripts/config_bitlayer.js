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
    "Flashlender_wbtc": {
      "constructorArguments": {
        "protocolFee_": toWad('0')
      },
      "initialDebtCeiling": toWad('100000000'),
    },
    "WBTC": "0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F", // Wrapped BTC on Bitlayer
    "BLBTC": "0x4e0dd7c16d2bbf873335cc21c72663b3eae23014", // BLBTC collateral asset
    "WETH": "0x0000000000000000000000000000000000000000", // WETH not available on Bitlayer (placeholder)
    "PenpieHelper": "0x0000000000000000000000000000000000000000", // PenpieHelper not available on Bitlayer
    "ACL": "", // To be filled after core deployment
    "AddressProviderV3": "", // To be filled after core deployment
    "ContractsRegister": "", // To be filled after core deployment
    "PoolV3_lpWBTC": "", // To be filled after WBTC pool deployment
    "FlashlenderLPWBTC": "", // To be filled after deployment
    "VaultRegistry": "", // To be filled after deployment
    "ProxyRegistry": "", // To be filled after deployment
    "PoolQuotaKeeperV3": "", // To be filled after deployment
    "GaugeV3": "", // To be filled after deployment
    "Actions": {
      "SwapAction": {
        "constructorArguments": {
          "balancerVault": "0x0000000000000000000000000000000000000000", // Balancer not available on Bitlayer
          "uniV3Router": "0x0000000000000000000000000000000000000000", // Uniswap V3 not available on Bitlayer
          "pendleRouter": "0x0000000000000000000000000000000000000000", // Pendle not available on Bitlayer
          "kyberRouter": "0x0000000000000000000000000000000000000000", // Kyber not available on Bitlayer
          "tranchessRouter": "0x0000000000000000000000000000000000000000", // Tranchess not available on Bitlayer
          "spectraRouter": "0x0000000000000000000000000000000000000000" // Spectra not available on Bitlayer
        }
      },
      "PoolAction": {
        "constructorArguments": {
          "balancerVault": "0x0000000000000000000000000000000000000000", // Balancer not available on Bitlayer
          "pendleRouter": "0x0000000000000000000000000000000000000000", // Pendle not available on Bitlayer
          "tranchessRouter": "0x0000000000000000000000000000000000000000", // Tranchess not available on Bitlayer
          "spectraRouter": "0x0000000000000000000000000000000000000000" // Spectra not available on Bitlayer
        }
      },
    },
    "Gearbox": {
      "initialGlobalDebtCeiling": "115792089237316195423570985008687907853269984665640564039457584007913129639935", // max uint256
    },
    "Treasury_wbtc": {
      "constructorArguments": {
        "payees":[
          "0xA719A90a173E8F00618596ffb594F5FfA79d915D", // Admin address (update as needed)
          "stakingLpWBTC" // Reference to staking contract - will be resolved during deployment
        ],
        "shares":[
          200, // 20% to admin
          800  // 80% to staking contract
        ],
        "admin": "deployer"
      }
    },
  },
  "Pools": {
    "Pool LpWBTC": {
      "name": "Loop Liquidity Pool - WBTC",
      "symbol": "lpWBTC",
      "wrappedToken": "0x0000000000000000000000000000000000000000", // No wrapped token for WBTC
      "treasury": "Treasury_wbtc", // Reference to treasury config key
      "underlier": "0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F", // WBTC on Bitlayer
      "interestRateModel": {
        "U_1": 7000, // U_1 - Optimal utilization for BTC (70%)
        "U_2": 9000, // U_2 - High utilization threshold for BTC (90%)
        "R_base": 200, // R_base - Base rate (2%)
        "R_slope1": 800, // R_slope1 - Slope before optimal utilization
        "R_slope2": 2500, // R_slope2 - Slope after optimal utilization
        "R_slope3": 10000, // R_slope3 - High penalty slope after U_2
      }, 
    }
  },
  "Vendors": {
  },
  "Vaults": {
    "Vaults_BLBTC": {
      name: "Vaults_BLBTC",
      description: "This vault allows for borrowing WBTC against BLBTC collateral",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "Oracle_BLBTC",
        deploymentArguments: {
          // Oracle configuration for BLBTC 
          "token": "0x4e0dd7c16d2bbf873335cc21c72663b3eae23014", // BLBTC address
          "stalePeriod": 3600, // 1 hour stale period
          "twapWindow": 1800, // 30 minutes TWAP window
          "twapEnabled": true
        },
      },
      token: "0x4e0dd7c16d2bbf873335cc21c72663b3eae23014", // BLBTC collateral token
      poolAddress: "", // Will be filled with WBTC pool address after deployment
      tokenSymbol: "LOOP-BLBTC",
      tokenScale: toWad("1.0"),
      protocolIcon: null,
      deploymentArguments: {
          constants: {
              protocolFee: toWad("0.01"), // 1% protocol fee
          },
          configs: {
              debtFloor: toWad("0.001"), // 0.001 WBTC 
              liquidationRatio: toWad("1.1"),
              liquidationPenalty: toWad("0.99"),
              liquidationDiscount: toWad("0.98"), 
              roleAdmin: "deployer",
              vaultAdmin: "deployer",
              pauseAdmin: "deployer",
          },
          debtCeiling: toWad("1000"), // 1000 WBTC debt ceiling (~$30M at $30k BTC)
      },
      quotas: {
          minRate: 100, // 1% minimum rate
          maxRate: 5000, // 50% maximum rate
      },
      "RewardManager": {
        "artifactName": "src/reward/RewardManager.sol:RewardManager",
        "constructorArguments": [
        ]
      }
    },
  },
 
  "Tokenomics":{
  }
};
