const { BigNumber } = require('ethers');
const { BalancerSDK, Network, PoolType } = require('@balancer-labs/sdk');
const axios = require('axios');

const toWad = ethers.utils.parseEther;

async function attachContract(name, address) {
    return await ethers.getContractAt(name, address);
}

async function getSignerAddress() {
    return (await (await ethers.getSigners())[0].getAddress());
}

const deployPool = async () =>{
    const url = process.env.TENDERLY_FORK_URL;
    const value = BigNumber.from(10).pow(16);
    const WETH = `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
    const PoolV3 = {
        address: "0xa684EAf215ad323452e2B2bF6F817d4aa5C116ab"
    }
    const signer = await getSignerAddress();

    const reqData = {
        jsonrpc: "2.0",
        method: "tenderly_setErc20Balance",
        params: [
          WETH,
          [signer],
          value.toHexString()
        ],
        id: "1234"
      };
    
      try {
        const response = await axios.post(url, reqData, {
          headers: {
            'Content-Type': 'application/json'
          }
        });
        console.log('Tenderly response:', response.data);
      } catch (error) {
        console.error('Error sending POST request to Tenderly:', error);
      }



    const poolv3Contract = await attachContract('PoolV3', PoolV3.address);
    let weth = await attachContract('ERC20', WETH);

    await weth.approve(PoolV3.address, value.div(2));
    console.log("approved pool spend weth")
    await poolv3Contract.deposit(value.div(2), signer);

    const balancer = new BalancerSDK({
        network: Network.MAINNET,
        rpcUrl: process.env.MAINNET_RPC_URL,
    });

    const poolTokens = [WETH, PoolV3.address];

    await weth.approve(balancer.contracts.vault.address, value.div(2));
    await poolv3Contract.approve(balancer.contracts.vault.address, value.div(2));

    console.log("approved balancer pool spend")

    const weightedPoolFactory = balancer.pools.poolFactory.of(PoolType.Weighted);
    const poolParameters = {
        name: 'WETH-lpETH',
        symbol: 'WETH-lpETH',
        tokenAddresses: poolTokens,
        normalizedWeights: [
        toWad('0.5').toString(),
        toWad('0.5').toString(),
        ],
        rateProviders: [ethers.constants.AddressZero, ethers.constants.AddressZero],
        swapFeeEvm: toWad('0.005').toString(),
        owner: signer,
    };

    const { to, data } = weightedPoolFactory.create(poolParameters);
    const deployer = (await ethers.getSigners())[0]

    const receipt = await (
        await deployer.sendTransaction({
        from: signer,
        to,
        data,
        })
    ).wait();

    console.log('Pool created with receipt:', receipt);

    const { poolAddress, poolId } =
        await weightedPoolFactory.getPoolAddressAndIdWithReceipt(
        deployer.provider,
        receipt
        );

    const amountsIn = [
        value.div(2).toString(),
        value.div(2).toString(),
    ];

    const initJoinParams = weightedPoolFactory.buildInitJoin({
        joiner: signer,
        poolId,
        poolAddress,
        tokensIn: poolTokens,
        amountsIn,
    });
    
    await deployer.sendTransaction({
        to: initJoinParams.to,
        data: initJoinParams.data,
    });

    console.log('Joined pool');

    const tokens = await balancer.contracts.vault.getPoolTokens(poolId);
    console.log('Pool Tokens Addresses: ' + tokens.tokens);
    console.log('Pool Tokens balances: ' + tokens.balances);

}

deployPool()