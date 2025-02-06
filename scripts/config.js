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
          "stakingLpEth"
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
    "SpectraVault": {
      "name": "Spectra-PT/IBT",
      "description": "This vault allows for borrowing and lending of assets",
      "poolAddress": "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab",
      "type": "CDPVaultSpectra",
      "oracle": {
        "type": "SpectraYnETHOracle",
        "deploymentArguments": {
          "curvePool": "0x08DA2b1EA8f2098D44C8690dDAdCa3d816c7C0d5",
          "ynETH": "0x09db87A538BD693E9d08544577d5cCfAA6373A48",
          "spectraYnETH": "0x6e0dccf49D095F8ea8920A8aF03D236FA167B7E0",
        }
      },
      "token": "0x85F05383f7Cb67f35385F7bF3B74E68F4795CbB9",
      "tokenScale": toWad('1.0'),
      "deploymentArguments": {
        "constants": {
          "protocolFee": toWad('0.01'),
        },
        "configs": {
            "debtFloor": toWad('1'),
            "liquidationRatio": toWad('1.1'),
            "liquidationPenalty": toWad('0.99'),
            "liquidationDiscount": toWad('0.98'),
            "roleAdmin": "deployer",
            "vaultAdmin": "deployer",
            "pauseAdmin": "deployer",
        },
        "debtCeiling": toWad('100000000')
      },
      "quotas": {
        "minRate": 100,
        "maxRate": 10000
      }
    },
  },
 
  "Tokenomics":{
  }
};
