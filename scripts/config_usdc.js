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
    "PenpieHelper": "0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "PoolV3_LpUSD": "0x0eecBDbF7331B8a50FCd0Bf2C267Bf47BD876054",
    "Flashlender_usdc":"0x663A68f2B5ED9194EEC31C4Af57C384adB1886A2",
    "AddressProviderV3": "0x9613E12A424B4CbaCF561F0ec54b418c76d6B26D",
    "VaultRegistry": "0x28ae6D200523E3af8372B689dfF6041a8bA019eD",
    "PRBProxyRegistry": "0xC63e9279410d37C0A25D094e26Cddbb73aEd7d95",
    "GaugeV3":"0x8D26E325205C53b204A9BEB46F88a98c3f0e7E13",
    "PoolQuotaKeeperV3":"0x36CE68477cDF24571f7C8f5dF0DAB7Ed6E65dFcF",

    "Actions": {
      "SwapAction": {
        "constructorArguments": {
          "balancerVault": "0xBA12222222228d8Ba445958a75a0704d566BF2C8",
          "uniV3Router": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
          "pendleRouter": "0x888888888889758F76e7103c6CbF23ABbF58F946",
          "kyberRouter": "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5",
          "tranchessRouter": "0x63BAEe33649E589Cc70435F898671461B624CBCc",
          "spectraRouter": "0xD733e545C65d539f588d7c3793147B497403F0d2"
        }
      },
      "PoolAction": {
        "constructorArguments": {
          "balancerVault": "0xBA12222222228d8Ba445958a75a0704d566BF2C8",
          "pendleRouter": "0x888888888889758F76e7103c6CbF23ABbF58F946",
          "tranchessRouter": "0x63BAEe33649E589Cc70435F898671461B624CBCc",
          "spectraRouter": "0xD733e545C65d539f588d7c3793147B497403F0d2"
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
    //   "LpUSD": {
    //   "name": "Loop USD - lpUSD",
    //   "symbol": "lpUSD",
    //   "wrappedToken": "0x0000000000000000000000000000000000000000",
    //   "treasury": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
    //   "underlier": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", //USDC
    //   "interestRateModel": {
    //     "U_1": 7000, // U_1
    //     "U_2": 9000, // U_2
    //     "R_base": 0, // R_base
    //     "R_slope1": 2000, // R_slope1
    //     "R_slope2": 2500, // R_slope2
    //     "R_slope3": 60000, // R_slope3
    //   },
    // }
  },
  "Vendors": {
  },
  "Vaults": {
    // "Vaults_USR": {
    //   name: "Vaults_USR",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVault",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "PendleLPOracle",
    //     deploymentArguments: {
    //       "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //       "market": "0x35a18cd59a214c9e797e14b1191b700eea251f6a",
    //       "twap": 180,
    //       "aggregator": "0x34ad75691e25A8E9b681AAA85dbeB7ef6561B42c", // usr-usd
    //       "stalePeriod": 88400,
    //     },
    //   },
    //   token: "0x35a18cd59a214c9e797e14b1191b700eea251f6a",
    //   poolAddress: "LpUSD",
    //   tokenSymbol: "LOOP-USR",
    //   tokenScale: toWad("1.0"),
    //   protocolIcon: null,
    //   deploymentArguments: {
    //       constants: {
    //           protocolFee: toWad("0.01"),
    //       },
    //       configs: {
    //           debtFloor: toWad("1"),
    //           liquidationRatio: toWad("1.1"),
    //           liquidationPenalty: toWad("0.99"),
    //           liquidationDiscount: toWad("0.98"),
    //           roleAdmin: "deployer",
    //           vaultAdmin: "deployer",
    //           pauseAdmin: "deployer",
    //       },
    //       debtCeiling: toWad("100000000"),
    //   },
    //   quotas: {
    //       minRate: 100,
    //       maxRate: 10000,
    //   },
    //   "RewardManager": {
    //     "artifactName": "src/pendle-rewards/RewardManager.sol:RewardManager",
    //     "constructorArguments": [
    //     ]
    //   }
    // },

    // "Vaults_eUSDe": {
    //   name: "Vaults_eUSDe",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVault",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "PendleLPOracle_eUSDe",
    //     deploymentArguments: {
    //       "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //       "market": "0xE93B4A93e80BD3065B290394264af5d82422ee70",
    //       "twap": 180,
    //       "eUSDe_vault": "0x90D2af7d622ca3141efA4d8f1F24d86E5974Cc8F",
    //       "usde_aggregator": "0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961",
    //       "usde_heartbeat": 86400, // 24 hours
    //       "usdc_aggregator": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
    //       "usdc_heartbeat": 86400, // 24 hours
    //       "stalePeriod": 88400,
    //     },
    //   },
    //   token: "0xE93B4A93e80BD3065B290394264af5d82422ee70",
    //   poolAddress: "LpUSD",
    //   tokenSymbol: "LOOP-eUSDe",
    //   tokenScale: toWad("1.0"),
    //   protocolIcon: null,
    //   deploymentArguments: {
    //       constants: {
    //           protocolFee: toWad("0.01"),
    //       },
    //       configs: {
    //           debtFloor: toWad("1"),
    //           liquidationRatio: toWad("1.1"),
    //           liquidationPenalty: toWad("0.99"),
    //           liquidationDiscount: toWad("0.98"),
    //           roleAdmin: "deployer",
    //           vaultAdmin: "deployer",
    //           pauseAdmin: "deployer",
    //       },
    //       debtCeiling: toWad("100000000"),
    //   },
    //   quotas: {
    //       minRate: 100,
    //       maxRate: 10000,
    //   },
    //   "RewardManager": {
    //     "artifactName": "src/pendle-rewards/RewardManager.sol:RewardManager",
    //     "constructorArguments": [
    //     ]
    //   }
    // },

    "Vaults_sUSDf": {
      name: "Vaults_sUSDf",
      description: "This vault allows for borrowing and lending of sUSDf assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "PendleLPOracle_sUSDf",
        deploymentArguments: {
          "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
          "market": "0x45f163e583d34b8e276445dd3da9ae077d137d72", // The LP token market
          "twap": 180,
          "usdf_usd_aggregator": "0xb177857a1799aA5F7fEb5799Fdf12CbE8fdF78B1", // USDf/USD Chainlink Oracle
          "usdf_usd_heartbeat": 86400, // 24 hours
          "usdc_usd_aggregator": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6", // USDC/USD Chainlink Oracle
          "usdc_usd_heartbeat": 86400, // 24 hours
          "stalePeriod": 88400,
        },
      },
      token: "0x45f163e583d34b8e276445dd3da9ae077d137d72",
      poolAddress: "LpUSD",
      tokenSymbol: "LOOP-sUSDf",
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
      "RewardManager": {
        "artifactName": "src/pendle-rewards/RewardManager.sol:RewardManager",
        "constructorArguments": [
        ]
      }
    },

    // "Vaults_sUSDa": {
    //   name: "Vaults_sUSDa",
    //   description: "This vault allows for borrowing and lending of sUSDa assets",
    //   type: "CDPVault",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "PendleLPOracle_sUSDa",
    //     deploymentArguments: {
    //       "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //       "market": "0xab39fb8e28def89e5df77c2788a811d881d7fc8e", // sUSDa market token
    //       "twap": 180,
    //       "pythPriceFeedsContract": "0x4305FB66699C3B2702D4d05CF36551390A4c69C6", // Pyth price feeds contract on mainnet
    //       "feedIdUSDaUSD": "0x3a1050a3c03354c94ed44acf808327f05b7f9d610f38644684f5ce4796cce27b", // USDa/USD Pyth feed ID
    //       "pyth_heartbeat": 3600, // 1 hour for Pyth feeds
    //       "usdc_usd_aggregator": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6", // USDC/USD Chainlink Oracle
    //       "usdc_usd_heartbeat": 86400, // 24 hours
    //       "stalePeriod": 88400,
    //     },
    //   },
    //   token: "0xab39fb8e28def89e5df77c2788a811d881d7fc8e", // sUSDa market token address
    //   poolAddress: "LpUSD",
    //   tokenSymbol: "LOOP-sUSDa",
    //   tokenScale: toWad("1.0"),
    //   protocolIcon: null,
    //   deploymentArguments: {
    //       constants: {
    //           protocolFee: toWad("0.01"),
    //       },
    //       configs: {
    //           debtFloor: toWad("1"),
    //           liquidationRatio: toWad("1.1"),
    //           liquidationPenalty: toWad("0.99"),
    //           liquidationDiscount: toWad("0.98"),
    //           roleAdmin: "deployer",
    //           vaultAdmin: "deployer",
    //           pauseAdmin: "deployer",
    //       },
    //       debtCeiling: toWad("100000000"),
    //   },
    //   quotas: {
    //       minRate: 100,
    //       maxRate: 10000,
    //   },
    //   "RewardManager": {
    //     "artifactName": "src/pendle-rewards/RewardManager.sol:RewardManager",
    //     "constructorArguments": [
    //     ]
    //   }
    // },

    // "Vaults_cUSDO": {
    //   name: "Vaults_cUSDO",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVault",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "PendleLPOracle_cUSDO",
    //     deploymentArguments: {
    //       "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //       "market": "0xA77c0DE4d26B7C97D1D42ABD6733201206122E25",
    //       "twap": 180,
    //       "curvePool": "0x90455bd11Ce8a67C57d467e634Dc142b8e4105Aa",
    //       "k": 0,
    //       "invert": true,
    //       "stalePeriod": 1
    //     },
    //   },
    //   token: "0xa77c0de4d26b7c97d1d42abd6733201206122e25",
    //   poolAddress: "LpUSD",
    //   tokenSymbol: "LOOP-cUSDO",
    //   tokenScale: toWad("1.0"),
    //   protocolIcon: null,
    //   deploymentArguments: {
    //       constants: {
    //           protocolFee: toWad("0.01"),
    //       },
    //       configs: {
    //           debtFloor: toWad("1"),
    //           liquidationRatio: toWad("1.1"),
    //           liquidationPenalty: toWad("0.99"),
    //           liquidationDiscount: toWad("0.98"),
    //           roleAdmin: "deployer",
    //           vaultAdmin: "deployer",
    //           pauseAdmin: "deployer",
    //       },
    //       debtCeiling: toWad("100000000"),
    //   },
    //   quotas: {
    //       minRate: 100,
    //       maxRate: 10000,
    //   },
    //   "RewardManager": {
    //     "artifactName": "src/pendle-rewards/RewardManager.sol:RewardManager",
    //     "constructorArguments": [
    //     ]
    //   }
    // },

    // "Vaults_syrupUSDC": {
    //   name: "Vaults_syrupUSDC",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVault",
    //   collateralType: "ERC20",
    //   oracle: {
    //       type: "PendleLPOracleRate",
    //       deploymentArguments: {
    //         "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //         "market": "0x9a63fa80b5ddfd3cab23803fdb93ad2c18f3d5aa",
    //         "twap": 180,
    //         "scale": 1000000000000
    //       },
    //   },
    //   token: "0x9a63fa80b5ddfd3cab23803fdb93ad2c18f3d5aa",
    //   tokenSymbol: "LOOP-syrupUSDC",
    //   poolAddress: "LpUSD",
    //   tokenScale: toWad("1.0"),
    //   protocolIcon: null,
    //   deploymentArguments: {
    //       constants: {
    //           protocolFee: toWad("0.01"),
    //       },
    //       configs: {
    //           debtFloor: toWad("1"),
    //           liquidationRatio: toWad("1.1"),
    //           liquidationPenalty: toWad("0.99"),
    //           liquidationDiscount: toWad("0.98"),
    //           roleAdmin: "deployer",
    //           vaultAdmin: "deployer",
    //           pauseAdmin: "deployer",
    //       },
    //       debtCeiling: toWad("100000000"),
    //   },
    //   quotas: {
    //       minRate: 100,
    //       maxRate: 10000,
    //   },
    //   "RewardManager": {
    //     "artifactName": "src/pendle-rewards/RewardManager.sol:RewardManager",
    //     "constructorArguments": [
    //     ]
    //   }
    // },
    
    // "Vaults_GHOUSR": {
    //   name: "Vaults_GHOUSR",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVaultSpectra",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "MockOracle",
    //     deploymentArguments: {
    //     },
    //   },
    //   token: "0x04f970bb02b4cf20e836e4a3fd434c5e60057936",
    //   poolAddress: "0x0eecBDbF7331B8a50FCd0Bf2C267Bf47BD876054",
    //   tokenSymbol: "LOOP-GHOUSR",
    //   tokenScale: toWad("1.0"),
    //   protocolIcon: null,
    //   deploymentArguments: {
    //       constants: {
    //           protocolFee: toWad("0.01"),
    //       },
    //       configs: {
    //           debtFloor: toWad("1"),
    //           liquidationRatio: toWad("1.1"),
    //           liquidationPenalty: toWad("0.99"),
    //           liquidationDiscount: toWad("0.98"),
    //           roleAdmin: "deployer",
    //           vaultAdmin: "deployer",
    //           pauseAdmin: "deployer",
    //       },
    //       debtCeiling: toWad("100000000"),
    //   },
    //   quotas: {
    //       minRate: 100,
    //       maxRate: 10000,
    //   },
    //   "RewardManager": {
    //     "artifactName": "src/spectra-rewards/RewardManagerSpectra.sol:RewardManagerSpectra",
    //     "constructorArguments": [
    //       "deployer",
    //       "0x38b9B4884a5581E96eD3882AA2f7449BC321786C"
    //     ]
    //   }
    // },
  },
 
  "Tokenomics":{
  }
};
