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
    "AddressProviderV3": "0x9613E12A424B4CbaCF561F0ec54b418c76d6B26D",
    "VaultRegistry": "0x28ae6D200523E3af8372B689dfF6041a8bA019eD",
    "PRBProxyRegistry": "0xC63e9279410d37C0A25D094e26Cddbb73aEd7d95",
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
    "Vaults_GHOUSR": {
      name: "Vaults_GHOUSR",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVaultSpectra",
      collateralType: "ERC20",
      oracle: {
        type: "MockOracle",
        deploymentArguments: {
        },
      },
      token: "0x04f970bb02b4cf20e836e4a3fd434c5e60057936",
      poolAddress: "0x0eecBDbF7331B8a50FCd0Bf2C267Bf47BD876054",
      tokenSymbol: "LOOP-GHOUSR",
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
        "artifactName": "src/spectra-rewards/RewardManagerSpectra.sol:RewardManagerSpectra",
        "constructorArguments": [
          "deployer",
          "0x38b9B4884a5581E96eD3882AA2f7449BC321786C"
        ]
      }
    },
    // "Vaults_sUSDe": {
    //   name: "Vaults_sUSDe",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVault",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "PendleLPOracle_sUSDe",
    //     deploymentArguments: {
    //       "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //       "market": "0xb162b764044697cf03617c2efbcb1f42e31e4766",
    //       "twap": 180,
    //       "usde_aggregator": "0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961",
    //       "usde_heartbeat": 86400, // 24 hours
    //       "usdc_aggregator": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
    //       "usdc_heartbeat": 86400, // 24 hours
    //       "stalePeriod": 3600,
    //     },
    //   },
    //   token: "0xb162b764044697cf03617c2efbcb1f42e31e4766",
    //   poolAddress: "LpUSD",
    //   tokenSymbol: "LOOP-sUSDe",
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
    // "Vaults_wstUSR": {
    //   name: "Vaults_wstUSR",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVault",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "WstUSR",
    //     deploymentArguments: {
    //       "pythPriceFeedsContract": "0x4305FB66699C3B2702D4d05CF36551390A4c69C6",
    //       "feedIdUSRUSD": "0x10b013adec14c0fe839ca0fe54cec9e4d0b6c1585ac6d7e70010dac015e57f9c",
    //       "wstUSRVault": "0x1202F5C7b4B9E47a1A484E8B270be34dbbC75055",
    //       "chainlinkUSDCFeed": "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
    //       "usdcHeartbeat": 86400, // 24 hours
    //       "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //       "market": "0x353d0b2efb5b3a7987fb06d30ad6160522d08426",
    //       "twap": 180,
    //       "stalePeriod": 3600,
    //     },
    //   },
    //   token: "0x353d0b2efb5b3a7987fb06d30ad6160522d08426",
    //   poolAddress: "LpUSD",
    //   tokenSymbol: "LOOP-wstUSR",
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
    //       type: "syrupUSDC",
    //       deploymentArguments: {
    //         "vault": "0x80ac24aa929eaf5013f6436cda2a7ba190f5cc0b",
    //         "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
    //         "market": "0x580e40c15261f7baf18ea50f562118ae99361096",
    //         "twap": 180,
    //         "stalePeriod": 3600,
    //       },
    //   },
    //   token: "0x580e40c15261f7baf18ea50f562118ae99361096",
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
  },
 
  "Tokenomics":{
  }
};
