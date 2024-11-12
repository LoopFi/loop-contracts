
const { BigNumber } = require('ethers');
require('dotenv').config();
const axios = require('axios');
let id = 1

const addresses = [
  "0xf0aB422942294ACc23b4125875dE8B4B652AC688",
  "0x567E5EB2dd8EC9A52F0D30e724Ab5Cdc5D619273",
  "0xf3ea9053135E299Cb84699195D29A3fBDE84BED7",
  "0x84202AfDEB1F88c686435a7b6Dd234c92c9Aae27"
]

const fundAccount = async (signer) => {
  const url = process.env.TENDERLY_FORK_URL;

  console.log({url})
  const value = BigNumber.from(10).pow(18).mul(1000);
  const WETH = `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`

  const weth = {
    jsonrpc: "2.0",
    method: "tenderly_setErc20Balance",
    params: [
      WETH,
      [signer],
      value.toHexString()
    ],
    id: (id++).toString()
  };

  try {
    const response = await axios.post(url, weth, {
      headers: {
        'Content-Type': 'application/json'
      }
    });
    console.log('Tenderly response:', response.data);
  } catch (error) {
    console.error('Error sending POST request to Tenderly:', error);
  }

  const ethData = {
    jsonrpc: "2.0",
    method: "tenderly_setBalance",
    params: [
      [signer],
      value.toHexString()
    ],
    id: (id++).toString()
  };

  try {
    const response = await axios.post(url, ethData, {
      headers: {
        'Content-Type': 'application/json'
      }
    });
    console.log('Tenderly response:', response.data);
  } catch (error) {
    console.error('Error sending POST request to Tenderly:', error);
  }

}

for (const address of addresses) {
  fundAccount(address);
}