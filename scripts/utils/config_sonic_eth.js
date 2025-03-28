const toWad = ethers.utils.parseEther;

// 1.00**(1/(60*60*24*366)) * 1e18, 0 decimals

module.exports = {
  "Core": {
    "Flashlender": {
      "constructorArguments": {
        "protocolFee_": toWad('0')
      },
      "initialDebtCeiling": toWad('100000000'),
    },
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "Actions": {
      "SwapAction": {
        "constructorArguments": {
          "balancerVault": "0xBA12222222228d8Ba445958a75a0704d566BF2C8",
          "uniV3Router": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
          "pendleRouter": "0x00000000005BBB0EF59571E58418F9a4357b68A0",
          "kyberRouter": "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5",
          "tranchessRouter": "0x63BAEe33649E589Cc70435F898671461B624CBCc",
          "spectraRouter": "0x3d20601ac0Ba9CAE4564dDf7870825c505B69F1a"
        }
      },
      "PoolAction": {
        "constructorArguments": {
          "balancerVault": "0xBA12222222228d8Ba445958a75a0704d566BF2C8",
          "pendleRouter": "0x00000000005BBB0EF59571E58418F9a4357b68A0",
          "tranchessRouter": "0x63BAEe33649E589Cc70435F898671461B624CBCc",
          "spectraRouter": "0x3d20601ac0Ba9CAE4564dDf7870825c505B69F1a"
        }
      },
    },
    "Gearbox": {
      "initialGlobalDebtCeiling": "115792089237316195423570985008687907853269984665640564039457584007913129639935",//max uint256
    },
    "Treasury": {
      "constructorArguments": {
        "payees":[
          "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
          "stakingLpUsdc"
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
    // "Pool LpETH": {
    //   "name": "Loop Liquidity Pool - WETH",
    //   "symbol": "lpETH",
    //   "poolAddress": "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
    //   "wrappedToken": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    //   "treasury": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
    //   "underlier": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", //WETH
    //   "interestRateModel": {
    //     "U_1": 7000, // U_1
    //     "U_2": 9000, // U_2
    //     "R_base": 0, // R_base
    //     "R_slope1": 2000, // R_slope1
    //     "R_slope2": 2500, // R_slope2
    //     "R_slope3": 60000, // R_slope3
    //   }, 
      "LpUSD": {
      "name": "LpUSD",
      "symbol": "lpUSD",
      "wrappedToken": "0x0000000000000000000000000000000000000000",
      "treasury": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
      "underlier": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", //USDC
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
    "Vaults_deUSD": {
      name: "Vaults_deUSD",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "MockOracle",
        deploymentArguments: {},
      },
      token: "0x09d484b738dd85ce3953102453e91507982121d0",
      poolAddress: "LpUSD",
      tokenSymbol: "LOOP-deUSD",
      tokenScale: toWad("1.0"),
      protocolIcon: null,
      deploymentArguments: {
          constants: {
              protocolFee: toWad("0.01"),
          },
          configs: {
              debtFloor: toWad("1"),
              liquidationRatio: toWad("1.1"),
              liquidationPenalty: toWad("0.99"),
              liquidationDiscount: toWad("0.98"),
              roleAdmin: "deployer",
              vaultAdmin: "deployer",
              pauseAdmin: "deployer",
          },
          debtCeiling: toWad("100000000"),
      },
      quotas: {
          minRate: 100,
          maxRate: 10000,
      },
    },
    "Vaults_sUSDe": {
      name: "Vaults_sUSDe",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "PendleLPOracle",
        deploymentArguments: {
          "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
          "market": "0x85667e484a32d884010cf16427d90049ccf46e97",
          "twap": 180,
          "aggregator": "0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22",
          "stalePeriod": 3600,
        },
      },
      token: "0xcdd26eb5eb2ce0f203a84553853667ae69ca29ce",
      poolAddress: "LpUSD",
      tokenSymbol: "LOOP-sUSDe",
      tokenScale: toWad("1.0"),
      protocolIcon: null,
      deploymentArguments: {
          constants: {
              protocolFee: toWad("0.01"),
          },
          configs: {
              debtFloor: toWad("1"),
              liquidationRatio: toWad("1.1"),
              liquidationPenalty: toWad("0.99"),
              liquidationDiscount: toWad("0.98"),
              roleAdmin: "deployer",
              vaultAdmin: "deployer",
              pauseAdmin: "deployer",
          },
          debtCeiling: toWad("100000000"),
      },
      quotas: {
          minRate: 100,
          maxRate: 10000,
      },
    },
    "Vaults_wstUSR": {
      name: "Vaults_wstUSR",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "WstUSR",
        deploymentArguments: {
          "pythPriceFeedsContract": "0x4305FB66699C3B2702D4d05CF36551390A4c69C6",
          "feedIdUSRUSD": "0x10b013adec14c0fe839ca0fe54cec9e4d0b6c1585ac6d7e70010dac015e57f9c",
          "wstUSRVault": "0x1202F5C7b4B9E47a1A484E8B270be34dbbC75055",
          "chainlinkUSDCFeed": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
          "usdcHeartbeat": 86400, // 24 hours
          "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
          "market": "0x353d0b2efb5b3a7987fb06d30ad6160522d08426",
          "twap": 180,
          "stalePeriod": 3600,
        },
      },
      token: "0x353d0b2efb5b3a7987fb06d30ad6160522d08426",
      poolAddress: "LpUSD",
      tokenSymbol: "LOOP-wstUSR",
      tokenScale: toWad("1.0"),
      protocolIcon: null,
      deploymentArguments: {
          constants: {
              protocolFee: toWad("0.01"),
          },
          configs: {
              debtFloor: toWad("1"),
              liquidationRatio: toWad("1.1"),
              liquidationPenalty: toWad("0.99"),
              liquidationDiscount: toWad("0.98"),
              roleAdmin: "deployer",
              vaultAdmin: "deployer",
              pauseAdmin: "deployer",
          },
          debtCeiling: toWad("100000000"),
      },
      quotas: {
          minRate: 100,
          maxRate: 10000,
      },
    },
    "Vaults_syrupUSDC": {
      name: "Vaults_syrupUSDC",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
          type: "syrupUSDC",
          deploymentArguments: {
            "vault": "0x80ac24aa929eaf5013f6436cda2a7ba190f5cc0b",
            "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
            "market": "0x580e40c15261f7baf18ea50f562118ae99361096",
            "twap": 180,
            "stalePeriod": 3600,
          },
      },
      token: "0x580e40c15261f7baf18ea50f562118ae99361096",
      tokenSymbol: "LOOP-syrupUSDC",
      poolAddress: "LpUSD",
      tokenScale: toWad("1.0"),
      protocolIcon: null,
      deploymentArguments: {
          constants: {
              protocolFee: toWad("0.01"),
          },
          configs: {
              debtFloor: toWad("1"),
              liquidationRatio: toWad("1.1"),
              liquidationPenalty: toWad("0.99"),
              liquidationDiscount: toWad("0.98"),
              roleAdmin: "deployer",
              vaultAdmin: "deployer",
              pauseAdmin: "deployer",
          },
          debtCeiling: toWad("100000000"),
      },
      quotas: {
          minRate: 100,
          maxRate: 10000,
      },
    },
  },
 
  "Tokenomics":{
  }
};
