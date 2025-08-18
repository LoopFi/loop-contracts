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
    "Flashlender_usdce": {
      "constructorArguments": {
        "protocolFee_": toWad('0')
      },
      "initialDebtCeiling": toWad('100000000'),
    },
    "WXDC": "0x951857744785E80e2De051c32EE7b25f9c458C42", // XDC native token wrapped
    "USDC": "0xcc0587aebda397146cc828b445db130a94486e74", // USDC on XDC
    "WETH": "0xa7348290de5cf01772479c48D50dec791c3fC212", // WETH on XDC
    "PenpieHelper": "0x0000000000000000000000000000000000000000", // PenpieHelper not available on XDC
    "AddressProviderV3": "0xE67f77af54EdA6B92f2dBaB272b8C0817ae0bCa3",
    "PoolV3_LpXDC": "0xED166436559Fd3d7f44cb00CACDA96EB999D789e",
    "PoolV3_lpUSDCe": "0x235e49CC709F9e262814795c00eabe73709ef8E2",
    "FlashlenderLPXDC": "", // To be filled after deployment
    "FlashlenderLPUSDC": "", // To be filled after deployment
    "VaultRegistry": "", // To be filled after deployment
    "ProxyRegistry": "", // To be filled after deployment
    "PoolQuotaKeeperV3": "0x796e374f741AfA9205B61328363404DA047CB5bC", // PoolQuotaKeeperV3_LpXDC
    "GaugeV3": "0x535F701F85F75a39D93b50E3dD04a7cf137F1EA6", // GaugeV3_LpXDC
    "Actions": {
      "SwapAction": {
        "constructorArguments": {
          "balancerVault": "0x0000000000000000000000000000000000000000", // Balancer not available on XDC
          "uniV3Router": "0x0000000000000000000000000000000000000000", // Uniswap V3 not available on XDC
          "pendleRouter": "0x0000000000000000000000000000000000000000", // Pendle not available on XDC
          "kyberRouter": "0x0000000000000000000000000000000000000000", // Kyber not available on XDC
          "tranchessRouter": "0x0000000000000000000000000000000000000000", // Tranchess not available on XDC
          "spectraRouter": "0x0000000000000000000000000000000000000000" // Spectra not available on XDC
        }
      },
      "PoolAction": {
        "constructorArguments": {
          "balancerVault": "0x0000000000000000000000000000000000000000", // Balancer not available on XDC
          "pendleRouter": "0x0000000000000000000000000000000000000000", // Pendle not available on XDC
          "tranchessRouter": "0x0000000000000000000000000000000000000000", // Tranchess not available on XDC
          "spectraRouter": "0x0000000000000000000000000000000000000000" // Spectra not available on XDC
        }
      },
    },
    "Gearbox": {
      "initialGlobalDebtCeiling": "115792089237316195423570985008687907853269984665640564039457584007913129639935", // max uint256
    },
    "Treasury_usdce": {
      "constructorArguments": {
        "payees":[
          "0xA719A90a173E8F00618596ffb594F5FfA79d915D",
          "0xe1987f6cD0b8823a033c29d640596757492479BD" // StakingLPUSDCE
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
    "Pool LpUSDC": {
      "name": "Loop Liquidity Pool - USDC.e",
      "symbol": "lpUSDCe",
      "wrappedToken": "0x0000000000000000000000000000000000000000", //
      "treasury": "", // To be filled with actual treasury address
      "underlier": "0xcc0587aebda397146cc828b445db130a94486e74", // USDC.E
      "interestRateModel": {
        "U_1": 8000, // U_1 - Higher utilization target for stablecoin
        "U_2": 9500, // U_2 - Higher optimal utilization for stablecoin
        "R_base": 0, // R_base
        "R_slope1": 1000, // R_slope1 - Lower slope for stablecoin
        "R_slope2": 2000, // R_slope2 - Moderate slope
        "R_slope3": 50000, // R_slope3 - High penalty slope
      }, 
    }
  },
  "Vendors": {
  },
  "Vaults": {
    "Vaults_scrvUSD": {
      name: "Vaults_scrvUSD",
      description: "This vault allows for borrowing and lending of scrvUSD assets",
      type: "CDPVault",
      collateralType: "ERC20",
      oracle: {
        type: "Oracle_scrvUSD",
        deploymentArguments: {
          "curvePool": "0x24894F0c4f80837d61CA21730A75Fa216FED7200",
          "scrvUSDRateXDC": "0x09F8D940EAD55853c51045bcbfE67341B686C071", // The LP token market
          "scrvUSD": "0x3d8EADb739D1Ef95dd53D718e4810721837c69c1",
          "k": 0
        },
      },
      token: "0x3d8EADb739D1Ef95dd53D718e4810721837c69c1",
      poolAddress: "0x235e49CC709F9e262814795c00eabe73709ef8E2", // USDC.e pool address
      tokenSymbol: "LOOP-scrvUSD",
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