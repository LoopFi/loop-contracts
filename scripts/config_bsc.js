const toWad = ethers.utils.parseEther;

// 1.00**(1/(60*60*24*366)) * 1e18, 0 decimals

module.exports = {
    Core: {
        WETH: "0x0000000000000000000000000000000000000000",
        Flashlender: {
            constructorArguments: {
                protocolFee_: toWad("0"),
            },
            initialDebtCeiling: toWad("100000000"),
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
                payees: ["0xE5e0898121C0F978f2fde415c1579CeDD04FEB95", "stakingLpEth"],
                shares: [200, 800],
                admin: "deployer",
            },
        },
        Gearbox: {
            initialGlobalDebtCeiling: "115792089237316195423570985008687907853269984665640564039457584007913129639935", //max uint256
        },
    },
    Pools: {
        LiquidityPool: {
            wrappedToken: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // wBNB
            name: "Loop BNB - lpBNB",
            symbol: "lpBNB",
            treasury: "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
            underlier: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
        },
    },
    Vaults: {
        CDPVault: {
            name: "ClisBNB",
            description: "This vault allows for borrowing and lending of assets",
            type: "CDPVault",
            collateralType: "ERC20",
            poolAddress: "0xED166436559Fd3d7f44cb00CACDA96EB999D789e",
            oracle: {
                type: "ListaOracle",
                deploymentArguments: {
                    ptOracle: "0x9a9fa8338dd5e5b2188006f1cd2ef26d921650c2",
                    listaStakeManager: "0x1adB950d8bB3dA4bE104211D5AB038628e477fE6",
                    market: "0x1d9d27f0b89181cf1593ac2b36a37b444eb66bee",
                    twap: "180",
                    stalePeriod: "1800",
                },
            },
            token: "0x1d9d27f0b89181cf1593ac2b36a37b444eb66bee",
            tokenSymbol: "LOOP-ClisBNB",
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
    LinearInterestRateModelV3: {
        U_1: 7000, // U_1
        U_2: 9000, // U_2
        R_base: 0, // R_base
        R_slope1: 1500,
        R_slope2: 1875,
        R_slope3: 45000
    },
};
