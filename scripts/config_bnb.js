const toWad = ethers.utils.parseEther;

// 1.00**(1/(60*60*24*366)) * 1e18, 0 decimals

module.exports = {
  "Core": {
    "Gearbox": {
      "initialGlobalDebtCeiling": "115792089237316195423570985008687907853269984665640564039457584007913129639935",//max uint256
    },
  },
  "Pools": {
    "LiquidityPool": {
      "wrappedToken": "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // wBNB
      "name": "Loop BNB - lpBNB",
      "symbol": "lpBNB",
      "treasury": "0xE5e0898121C0F978f2fde415c1579CeDD04FEB95",
      "underlier": "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"
    }
  },
  "LinearInterestRateModelV3": {
    "U_1": 7000, // U_1
    "U_2": 9000, // U_2
    "R_base": 0, // R_base
    "R_slope1": 2000, // R_slope1
    "R_slope2": 2500, // R_slope2
    "R_slope3": 60000, // R_slope3
  }
};
