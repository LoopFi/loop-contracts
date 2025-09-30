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
    "ACL": "0xE67f77af54EdA6B92f2dBaB272b8C0817ae0bCa3", // 
    "AddressProviderV3": "0x9613E12A424B4CbaCF561F0ec54b418c76d6B26D", // 
    "ContractsRegister": "0x0aB39D2DA8160E64117C9B5CE88efD68FB8Bf693", //
    "PoolV3_lpWBTC": "", // To be filled after WBTC pool deployment
    "FlashlenderLPWBTC": "", // To be filled after deployment
    "VaultRegistry": "", // To be filled after deployment
    "ProxyRegistry": "", // To be filled after deployment (PRBProxyRegistry)
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
      "wrappedToken": "0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F", // WBTC
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
        type: "PushOracle",
        deploymentArguments: {
          // PushOracle configuration for BLBTC
          "admin": "deployer", // Deployer as admin
          "manager": "deployer", // Deployer as manager for now
          "pusher": "0x5f73012306334eB1D49E4980B9121dedEAe25129"
        },
        oracleConfig: {
          "token": "0x4e0dd7c16d2bbf873335cc21c72663b3eae23014", // BLBTC address
          "stalePeriod": 86400, // 24 hours stale period (6 hour updates + buffer)
          "twapWindow": 43200, // 12 hours TWAP window (2x update frequency)
          "twapEnabled": true
        }
      },
      token: "0x4e0dd7c16d2bbf873335cc21c72663b3eae23014", // BLBTC collateral token
      poolAddress: "PoolV3_lpWBTC", // Reference to deployed WBTC pool
      tokenSymbol: "LOOP-BLBTC",
      tokenScale: toWad("1.0"),
      protocolIcon: null,
      deploymentArguments: {
          constants: {
              protocolFee: toWad("0.01"), // 1% protocol fee
          },
          configs: {
              debtFloor: toWad("0.001"), // 0.001 WBTC 
              liquidationRatio: toWad("1.6667"),
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
