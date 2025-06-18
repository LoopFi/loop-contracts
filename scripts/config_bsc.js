const toWad = ethers.utils.parseEther;

// 1.00**(1/(60*60*24*366)) * 1e18, 0 decimals

module.exports = {
    Core: {
        WETH: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
        "PoolV3_LpBNB": "0xED166436559Fd3d7f44cb00CACDA96EB999D789e",
        "PoolV3_LpBTC": "0xa02fcc8493856b5bd7fA5099f5a631A6cb77fBd1",
        "VaultRegistry": "0xcFad68BE82E5230C40b04629ee2AF6D1F0E25E93",
        "AddressProviderV3": "0x9613E12A424B4CbaCF561F0ec54b418c76d6B26D",
        "ProxyRegistry": "0xD83B0a990ac3dBc9A5F3862b84883Da78F286283",
        "PoolQuotaKeeperV3": "0x7fC6f72E895F1ed110799f5d6594149e4A0B7Ff3",
        "GaugeV3": "0x0D7909318B497Da3060BcD371448E4629be2705D",
        "Flashlender":"0x0FD87690fcd1Ae9245edB7de8c598AEcCFaf427c",
        "PenpieHelper": "0x0000000000000000000000000000000000000000",
        "SwapAction": "0x5f96431ee187983B00e53068B55A8011aea6b708",
        "PoolAction": "0x4F7280739Ba53591dE300277262CF7f7E038F24F",

        "Flashlender_btc": {
            "constructorArguments": {
              "protocolFee_": toWad('0')
            },
            "initialDebtCeiling": toWad('100000000'),
          },

        Actions: {
            SwapAction: {
                constructorArguments: {
                    balancerVault: "0x0000000000000000000000000000000000000000",
                    uniV3Router: "0x0000000000000000000000000000000000000000",
                    pendleRouter: "0x888888888889758F76e7103c6CbF23ABbF58F946",
                    kyberRouter: "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5",
                    tranchessRouter: "0x0000000000000000000000000000000000000000",
                    spectraRouter: "0x0000000000000000000000000000000000000000",
                },
            },
            PoolAction: {
                constructorArguments: {
                    balancerVault: "0x0000000000000000000000000000000000000000",
                    pendleRouter: "0x888888888889758F76e7103c6CbF23ABbF58F946",
                    tranchessRouter: "0x0000000000000000000000000000000000000000",
                    spectraRouter: "0x0000000000000000000000000000000000000000",
                },
            },
        },
        Treasury: {
            constructorArguments: {
                payees: ["0xE5e0898121C0F978f2fde415c1579CeDD04FEB95", "stakingLpBTC"],
                shares: [200, 800],
                admin: "deployer",
            },
        },
        Gearbox: {
            initialGlobalDebtCeiling: "115792089237316195423570985008687907853269984665640564039457584007913129639935", //max uint256
        },
    },
    Pools: {
        // LiquidityPool: {
        //     wrappedToken: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // wBNB
        //     name: "Loop BNB - lpBNB",
        //     symbol: "lpBNB",
        //     treasury: "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
        //     underlier: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
        // },

        LiquidityPoolBTCB: {
            wrappedToken: "0x0000000000000000000000000000000000000000",
            name: "Loop BTC - lpBTC",
            symbol: "lpBTC",
            treasury: "0x0000000000000000000000000000000000000000",
            underlier: "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c",
            "interestRateModel": {
                "U_1": 7000, // U_1
                "U_2": 9000, // U_2
                "R_base": 0, // R_base
                "R_slope1": 612, // R_slope1
                "R_slope2": 765, // R_slope2
                "R_slope3": 2040, // R_slope3
            },
        },
    },
    Vaults: {
        // CDPVault: {
        //     name: "ClisBNB-v2",
        //     description: "This vault allows for borrowing and lending of assets",
        //     type: "CDPVault",
        //     collateralType: "ERC20",
        //     poolAddress: "0xED166436559Fd3d7f44cb00CACDA96EB999D789e",
        //     oracle: {
        //         type: "ListaOracle",
        //         deploymentArguments: {
        //             ptOracle: "0x9a9fa8338dd5e5b2188006f1cd2ef26d921650c2",
        //             listaStakeManager: "0x0000000000000000000000000000000000000000",
        //             market: "0xBD577dDABb5a1672d3C786726b87A175de652b96",
        //             twap: "180",
        //             stalePeriod: "1800",
        //         },
        //     },
        //     token: "0xBD577dDABb5a1672d3C786726b87A175de652b96",
        //     tokenSymbol: "LOOP-ClisBNB",
        //     tokenScale: toWad("1.0"),
        //     protocolIcon: null,
        //     deploymentArguments: {
        //         constants: {
        //             protocolFee: toWad("0.01"),
        //         },
        //         configs: {
        //             debtFloor: toWad("1"),
        //             liquidationRatio: toWad("1.1"),
        //             liquidationPenalty: toWad("0.99"),
        //             liquidationDiscount: toWad("0.98"),
        //             roleAdmin: "deployer",
        //             vaultAdmin: "deployer",
        //             pauseAdmin: "deployer",
        //         },
        //         debtCeiling: toWad("100000000"),
        //     },
        //     quotas: {
        //         minRate: 100,
        //         maxRate: 10000,
        //     },
        //     "RewardManager": {
        //         "artifactName": "src/pendle-rewards/RewardManager.sol:RewardManager",
        //         "constructorArguments": [
        //         ]
        //     }
        // },

        CDPVault: {
            name: "ynCoBTCk",
            description: "This vault allows for borrowing and lending of assets",
            type: "CDPVault",
            collateralType: "ERC20",
            poolAddress: "LiquidityPoolBTCB",
            oracle: {
                type: "StaticOracle",
                deploymentArguments: {
                },
            },
            token: "0x132376b153d3cFf94615fe25712DB12CaAADf547",
            tokenSymbol: "LOOP-ynCoBTCk",
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
    LinearInterestRateModelV3: {
        U_1: 7000, // U_1
        U_2: 9000, // U_2
        R_base: 0, // R_base
        R_slope1: 1500,
        R_slope2: 1875,
        R_slope3: 45000
    },
};
