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
    // Balancer infrastructure for tokenomics
    "BalancerVault": "0xBA12222222228d8Ba445958a75a0704d566BF2C8",
    "WeightedPoolFactory": "0x897888115Ada5773E02aA29F775430BFB5F34c51",
    // Tokenomics contract addresses (will be populated during deployment)
    "LoopToken": "0x51Ebe928EDc7b9a937899B7bf17a76Be1f88367E",
    "BalancerPoolHelper": "0x7e785bb5122a30f55d45B8EFa87305007DeD5BA7",  
    "MultiFeeDistribution": null, // Will be set during deployment
    "PriceProvider": null, // Will be set during deployment
    // Governance addresses
    "LockZap": "deployer", // Will use deployer address ( also all actions will be added )
    "DAO": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95", // Dao Treasury
    "Treasury": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95", // Using existing treasury
    "PoolV3_LpUSD": "0x0eecBDbF7331B8a50FCd0Bf2C267Bf47BD876054",
    "PoolV3_LpETH": "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
    "FlashlenderLPEth": "0x6670CC1d4DEbe29eC12F1dA6D66a2A487431B3D5",
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
    // "Vaults_inwstETH": {
    //   name: "Vaults_inwstETH",
    //   description: "This vault allows for borrowing and lending of assets",
    //   type: "CDPVaultSpectra",
    //   collateralType: "ERC20",
    //   oracle: {
    //     type: "SpectraInwstETHOracle",
    //     deploymentArguments: {
    //         "wstEth": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
    //         "stETHClOracle": "0x86392dC19c0b719886221c78AB11eb8Cf5c52812",
    //         "stalePeriod": 24 * 60 * 60,
    //         "curvePool": "0xE119bad8a35B999f65b1e5Fd48c626C327DAa16B",
    //         "spectraIBT": "0xd89Fc47AacBB31E2bF23EC599F593A4876D8c18C",
    //     },
    //   },
    //   token: "0x2cd244f1f9a856c251d276103862dd4325985d2a",
    //   poolAddress: "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
    //   tokenSymbol: "LOOP-inwstETHs",
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
    "Vaults_tETH_January2026": {
      name: "Vaults_tETH_January2026",
      description: "This vault allows for borrowing and lending of assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "PendleLPOracleRate",
        deploymentArguments: {
            "ptOracle": "0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2",
            "market": "0x3DAF20E46708E556570159Eaf98eeE53A1A5b8A4",
            "twap": 180
        },
      },
      token: "0x3DAF20E46708E556570159Eaf98eeE53A1A5b8A4",
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
  },
 
  "Tokenomics": {
    "LoopToken": {
      "name": "Loop Token",
      "symbol": "LOOP", 
      "totalSupply": toWad("1000000000") // 1 billion tokens
    }
  },
  "Rewards": {
    "rewardsDuration": 30 * 24 * 60 * 60, // 30 days
    "rewardsLookback": 5 * 24 * 60 * 60,  // 5 days
    "lockDuration": 30 * 24 * 60 * 60,     // 30 days
    "burnRatio": 50000,                    // 50%
    "vestDuration": 30 * 24 * 60 * 60,     // 30 days
    "rewardsPerSecond": toWad("0.01"),     // 0.01 tokens per second
    "endingTimeCadence": 2 * 24 * 60 * 60, // 2 days
    "lockDurations": [
      30 * 24 * 60 * 60,  // 30 days
      90 * 24 * 60 * 60,  // 90 days  
      180 * 24 * 60 * 60, // 180 days
      365 * 24 * 60 * 60  // 365 days
    ],
    "rewardMultipliers": [1, 4, 10, 25] // Multipliers for each lock duration
  },
  "LiquidityPool": {
    "initializeOnDeploy": true,
    "poolName": "80LOOP-20WETH",
    "poolSymbol": "80LOOP-20WETH",
    "initialLiquidity": {
      "wethAmount": toWad("1000"),   // 1000 WETH
      "loopAmount": toWad("100000")  // 100,000 LOOP tokens (80/20 ratio)
    }
  }
};
