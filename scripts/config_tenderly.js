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
          "deployer",
          "stakingLpEth"
        ],
        "shares":[
          20,
          80
        ],
        "admin": "deployer"
      }
    },
  },
  "Pools": {
    "LiquidityPool": {
      "name": "Loop Liquidity Pool - WETH",
      "symbol": "lpETH",
      "wrappedToken": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
      "treasury": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
      "underlier": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" //WETH
    }
  },
  "Vendors": {
  },
  "Vaults": {
    "SpectraVault": {
      "name": "Spectra-PT/IBT",
      "description": "This vault allows for borrowing and lending of assets",
      "type": "CDPVaultSpectra",
      "collateralType": "ERC20",
      "lrt": '0x85F05383f7Cb67f35385F7bF3B74E68F4795CbB9',
      "lrtName": "SPT-PT/IBT-f",
      "oracle": {
        "type": "SpectraYnETHOracle",
        "deploymentArguments": {
          "curvePool": "0x08DA2b1EA8f2098D44C8690dDAdCa3d816c7C0d5",
          "ynETH": "0x09db87A538BD693E9d08544577d5cCfAA6373A48",
          "spectraYnETH": "0x6e0dccf49D095F8ea8920A8aF03D236FA167B7E0",
        }
      },
      "tokenPot": "0x0329aCa1a15139e2288E58c8a8a057b7723af4f2",
      "tokenIcon": "data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHhtbG5zOnhsaW5rPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5L3hsaW5rIiB3aWR0aD0iMjRweCIgaGVpZ2h0PSIyNHB4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIHZlcnNpb249IjEuMSI+CjxnIGlkPSJzdXJmYWNlMSI+CjxwYXRoIHN0eWxlPSIgc3Ryb2tlOm5vbmU7ZmlsbC1ydWxlOm5vbnplcm87ZmlsbDpyZ2IoMTUuMjk0MTE4JSw0NS44ODIzNTMlLDc5LjIxNTY4NiUpO2ZpbGwtb3BhY2l0eToxOyIgZD0iTSAxMiAyNCBDIDE4LjY0ODQzOCAyNCAyNCAxOC42NDg0MzggMjQgMTIgQyAyNCA1LjM1MTU2MiAxOC42NDg0MzggMCAxMiAwIEMgNS4zNTE1NjIgMCAwIDUuMzUxNTYyIDAgMTIgQyAwIDE4LjY0ODQzOCA1LjM1MTU2MiAyNCAxMiAyNCBaIE0gMTIgMjQgIi8+CjxwYXRoIHN0eWxlPSIgc3Ryb2tlOm5vbmU7ZmlsbC1ydWxlOmV2ZW5vZGQ7ZmlsbDpyZ2IoMTAwJSwxMDAlLDEwMCUpO2ZpbGwtb3BhY2l0eToxOyIgZD0iTSA1IDkuNTUwNzgxIEMgMy41NTA3ODEgMTMuMzk4NDM4IDUuNTUwNzgxIDE3Ljc1IDkuNDQ5MjE5IDE5LjE0ODQzOCBDIDkuNjAxNTYyIDE5LjI1IDkuNzUgMTkuNDQ5MjE5IDkuNzUgMTkuNjAxNTYyIEwgOS43NSAyMC4zMDA3ODEgQyA5Ljc1IDIwLjM5ODQzOCA5Ljc1IDIwLjQ0OTIxOSA5LjY5OTIxOSAyMC41IEMgOS42NTIzNDQgMjAuNjk5MjE5IDkuNDQ5MjE5IDIwLjgwMDc4MSA5LjI1IDIwLjY5OTIxOSBDIDYuNDQ5MjE5IDE5LjgwMDc4MSA0LjMwMDc4MSAxNy42NDg0MzggMy40MDIzNDQgMTQuODUxNTYyIEMgMS45MDIzNDQgMTAuMTAxNTYyIDQuNSA1LjA1MDc4MSA5LjI1IDMuNTUwNzgxIEMgOS4zMDA3ODEgMy41IDkuNDAyMzQ0IDMuNSA5LjQ0OTIxOSAzLjUgQyA5LjY1MjM0NCAzLjU1MDc4MSA5Ljc1IDMuNjk5MjE5IDkuNzUgMy44OTg0MzggTCA5Ljc1IDQuNjAxNTYyIEMgOS43NSA0Ljg1MTU2MiA5LjY1MjM0NCA1IDkuNDQ5MjE5IDUuMTAxNTYyIEMgNy40MDIzNDQgNS44NTE1NjIgNS43NSA3LjQ0OTIxOSA1IDkuNTUwNzgxIFogTSAxNC4zMDA3ODEgMy43NSBDIDE0LjM1MTU2MiAzLjU1MDc4MSAxNC41NTA3ODEgMy40NDkyMTkgMTQuNzUgMy41NTA3ODEgQyAxNy41IDQuNDQ5MjE5IDE5LjY5OTIxOSA2LjYwMTU2MiAyMC42MDE1NjIgOS40NDkyMTkgQyAyMi4xMDE1NjIgMTQuMTk5MjE5IDE5LjUgMTkuMjUgMTQuNzUgMjAuNzUgQyAxNC42OTkyMTkgMjAuODAwNzgxIDE0LjYwMTU2MiAyMC44MDA3ODEgMTQuNTUwNzgxIDIwLjgwMDc4MSBDIDE0LjM1MTU2MiAyMC43NSAxNC4yNSAyMC42MDE1NjIgMTQuMjUgMjAuMzk4NDM4IEwgMTQuMjUgMTkuNjk5MjE5IEMgMTQuMjUgMTkuNDQ5MjE5IDE0LjM1MTU2MiAxOS4zMDA3ODEgMTQuNTUwNzgxIDE5LjE5OTIxOSBDIDE2LjYwMTU2MiAxOC40NDkyMTkgMTguMjUgMTYuODUxNTYyIDE5IDE0Ljc1IEMgMjAuNDQ5MjE5IDEwLjg5ODQzOCAxOC40NDkyMTkgNi41NTA3ODEgMTQuNTUwNzgxIDUuMTQ4NDM4IEMgMTQuNDAyMzQ0IDUuMDUwNzgxIDE0LjI1IDQuODUxNTYyIDE0LjI1IDQuNjQ4NDM4IEwgMTQuMjUgMy45NDkyMTkgQyAxNC4yNSAzLjg1MTU2MiAxNC4yNSAzLjgwMDc4MSAxNC4zMDA3ODEgMy43NSBaIE0gMTIuMTQ4NDM4IDExLjMwMDc4MSBDIDE0LjI1IDExLjU1MDc4MSAxNS4zMDA3ODEgMTIuMTQ4NDM4IDE1LjMwMDc4MSAxMy44OTg0MzggQyAxNS4zMDA3ODEgMTUuMjUgMTQuMzAwNzgxIDE2LjMwMDc4MSAxMi44MDA3ODEgMTYuNTUwNzgxIEwgMTIuODAwNzgxIDE3Ljc1IEMgMTIuNzUgMTggMTIuNTk3NjU2IDE4LjE0ODQzOCAxMi4zOTg0MzggMTguMTQ4NDM4IEwgMTEuNjQ4NDM4IDE4LjE0ODQzOCBDIDExLjM5ODQzOCAxOC4xMDE1NjIgMTEuMjUgMTcuOTQ5MjE5IDExLjI1IDE3Ljc1IEwgMTEuMjUgMTYuNTUwNzgxIEMgOS41OTc2NTYgMTYuMzAwNzgxIDguODAwNzgxIDE1LjM5ODQzOCA4LjU5NzY1NiAxNC4xNDg0MzggTCA4LjU5NzY1NiAxNC4xMDE1NjIgQyA4LjU5NzY1NiAxMy44OTg0MzggOC43NSAxMy43NSA4Ljk0OTIxOSAxMy43NSBMIDkuODAwNzgxIDEzLjc1IEMgOS45NDkyMTkgMTMuNzUgMTAuMDk3NjU2IDEzLjg1MTU2MiAxMC4xNDg0MzggMTQuMDUwNzgxIEMgMTAuMzAwNzgxIDE0LjgwMDc4MSAxMC43NSAxNS4zNTE1NjIgMTIuMDUwNzgxIDE1LjM1MTU2MiBDIDEzIDE1LjM1MTU2MiAxMy42OTkyMTkgMTQuODAwNzgxIDEzLjY5OTIxOSAxNCBDIDEzLjY5OTIxOSAxMy4xOTkyMTkgMTMuMjUgMTIuODk4NDM4IDExLjg0NzY1NiAxMi42NDg0MzggQyA5Ljc1IDEyLjM5ODQzOCA4Ljc1IDExLjc1IDguNzUgMTAuMTAxNTYyIEMgOC43NSA4Ljg1MTU2MiA5LjY5OTIxOSA3Ljg1MTU2MiAxMS4xOTkyMTkgNy42NDg0MzggTCAxMS4xOTkyMTkgNi41IEMgMTEuMjUgNi4yNSAxMS4zOTg0MzggNi4xMDE1NjIgMTEuNTk3NjU2IDYuMTAxNTYyIEwgMTIuMzQ3NjU2IDYuMTAxNTYyIEMgMTIuNTk3NjU2IDYuMTQ4NDM4IDEyLjc1IDYuMzAwNzgxIDEyLjc1IDYuNSBMIDEyLjc1IDcuNjk5MjE5IEMgMTMuODk4NDM4IDcuODAwNzgxIDE0LjgwMDc4MSA4LjY0ODQzOCAxNSA5Ljc1IEwgMTUgOS44MDA3ODEgQyAxNSAxMCAxNC44NDc2NTYgMTAuMTQ4NDM4IDE0LjY0ODQzOCAxMC4xNDg0MzggTCAxMy44NDc2NTYgMTAuMTQ4NDM4IEMgMTMuNjk5MjE5IDEwLjE0ODQzOCAxMy41NTA3ODEgMTAuMDUwNzgxIDEzLjUgOS44OTg0MzggQyAxMy4yNSA5LjE0ODQzOCAxMi43NSA4Ljg1MTU2MiAxMS44NDc2NTYgOC44NTE1NjIgQyAxMC44NDc2NTYgOC44NTE1NjIgMTAuMzQ3NjU2IDkuMzAwNzgxIDEwLjM0NzY1NiAxMCBDIDEwLjM0NzY1NiAxMC42OTkyMTkgMTAuNjQ4NDM4IDExLjEwMTU2MiAxMi4xNDg0MzggMTEuMzAwNzgxIFogTSAxMi4xNDg0MzggMTEuMzAwNzgxICIvPgo8L2c+Cjwvc3ZnPgo=",
      "token": "0x85F05383f7Cb67f35385F7bF3B74E68F4795CbB9",
      "tokenSymbol": "LOOP-Spectra",
      "tokenScale": toWad('1.0'),
      "protocolIcon": null,
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
      }
    },
  },
  "LinearInterestRateModelV3": {
    "U_1": 7000, // U_1
    "U_2": 9000, // U_2
    "R_base": 0, // R_base
    "R_slope1": 2000, // R_slope1
    "R_slope2": 2500, // R_slope2
    "R_slope3": 60000, // R_slope3
  },  
  "Tokenomics":{
    "MultiFeeDistribution": {
      "lockZap": "0x0000000000000000000000000000000000000123",
      "dao": "0x0000000000000000000000000000000000000123",
      "treasury": "0x0000000000000000000000000000000000000123",
      "rewardsDuration": 2592000, // 30 days in seconds
      "rewardsLookback": 432000, // 5 days in seconds
      "lockDuration": 2592000, // 30 days in seconds
      "burnRatio": 50000, // 50%
      "vestDuration": 2592000 // 30 days in seconds
    },
    "IncentivesController": {
      "rewardsPerSecond": "120000000000000000", // 0.12 in WAD
      "endingTimeCadence": "172800", // 2 days in seconds
      "rewardAmount": "10000000000000000000000000", // 10 milion in WAD
    }
  }
};
