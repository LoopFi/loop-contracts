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
    "PenpieHelper": "0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4",
    "AddressProviderV3": "0x9613E12A424B4CbaCF561F0ec54b418c76d6B26D",
    "PoolV3_LpUSD": "0x0eecBDbF7331B8a50FCd0Bf2C267Bf47BD876054",
    "PoolV3_LpETH": "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
    "VaultRegistry": "0x28ae6D200523E3af8372B689dfF6041a8bA019eD",
    "ProxyRegistry": "0xC63e9279410d37C0A25D094e26Cddbb73aEd7d95",
    "PoolQuotaKeeperV3": "0x3cc6e65d333DadD9113f227F4da07cF4F9D0eeF9",
    "GaugeV3": "0x090052C12A5c744542b08006197C6824ACF00187",
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
          "stakingLpETH"
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
    "Pool LpETH": {
      "name": "Loop Liquidity Pool - WETH",
      "symbol": "lpETH",
      "poolAddress": "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
      "wrappedToken": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
      "treasury": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
      "underlier": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", //WETH
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
    "Vaults_tETH": {
      name: "Vaults_tETH",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "PendleLPOracleRate",
        deploymentArguments: {
            "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
            "market": "0xBDb8F9729d3194f75fD1A3D9bc4FFe0DDe3A404c",
            "twap": 180
        },
      },
      token: "0xBDb8F9729d3194f75fD1A3D9bc4FFe0DDe3A404c",
      poolAddress: "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
      tokenSymbol: "LOOP-tETH",
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
    "Vaults_uniETH": {
      name: "Vaults_uniETH",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "PendleLPOracleRate",
        deploymentArguments: {
            "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
            "market": "0xbba9baaa6b3107182147a12177e0f1ec46b8b072",
            "twap": 180
        },
      },
      token: "0xbba9baaa6b3107182147a12177e0f1ec46b8b072",
      poolAddress: "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
      tokenSymbol: "Loop-uniETH",
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
    "Vaults_rswETH": {
      name: "Vaults_rswETH",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "PendleLPOracleRate",
        deploymentArguments: {
            "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
            "market": "0xfd5cf95e8b886ace955057ca4dc69466e793fbbe",
            "twap": 180
        },
      },
      token: "0xfd5cf95e8b886ace955057ca4dc69466e793fbbe",
      poolAddress: "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
      tokenSymbol: "Loop-rswETH",
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
    "Vaults_puffETH": {
      name: "Vaults_puffETH",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "PendleLPOracleRate",
        deploymentArguments: {
            "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
            "market": "0x58612beb0e8a126735b19bb222cbc7fc2c162d2a",
            "twap": 180
        },
      },
      token: "0x58612beb0e8a126735b19bb222cbc7fc2c162d2a",
      poolAddress: "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
      tokenSymbol: "Loop-puffETH",
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
  },
 
  "Tokenomics":{
  }
};
