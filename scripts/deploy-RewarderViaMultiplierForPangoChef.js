const { Client, ContractCreateFlow, ContractFunctionParameters} = require('@hashgraph/sdk');
const { ethers } = require('hardhat');
require('dotenv').config({ path: '../.env' });

const myAccountId = process.env.MY_ACCOUNT_ID;
const myPrivateKey = process.env.MY_PRIVATE_KEY;

if (myAccountId == null || myPrivateKey == null) {
    throw new Error('Environment variables MY_ACCOUNT_ID and MY_PRIVATE_KEY must be present');
}

const client = Client.forTestnet();
client.setOperator(myAccountId, myPrivateKey);


// Change these variables
const pangoChefAddress = '0x000000000000000000000000000000000007029e';
const rewardInfos = [
    {
        rewardAddresses: ['0x00000000000000000000000000000000000274a3'],
        rewardMultipliers: [100000],
    },
];


async function main() {
    if (!ethers.utils.isAddress(pangoChefAddress) || parseInt(pangoChefAddress, 16) === 0) throw new Error(`Invalid PangoChef address`);

    for (const {rewardAddresses, rewardMultipliers} of rewardInfos) {
        if (rewardAddresses.length !== rewardMultipliers.length) throw new Error(`Mismatched arguments length`);
        if (rewardMultipliers.some(mult => parseInt(mult.toString()) !== mult)) throw new Error(`Invalid multiplier`);
        if (rewardAddresses.some(addr => !ethers.utils.isAddress(addr) || parseInt(addr, 16) === 0)) throw new Error(`Invalid reward address`);

        // Get the contract bytecode from Hardhat.
        const factory = await ethers.getContractFactory('RewarderViaMultiplierForPangoChef');
        const bytecode = factory.bytecode;

        console.log('Deploying RewarderViaMultiplierForPangoChef contract ...');

        // Create the deploy transaction.
        const contractCreate = new ContractCreateFlow()
            .setBytecode(bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddressArray(rewardAddresses) // rewardTokens
                    .addUint256Array(rewardMultipliers) // rewardMultipliers
                    .addUint256(8) // baseRewardTokenDecimals
                    .addAddress(pangoChefAddress) // chef
            )
            .setGas(1_000_000); // 853,234 - might need more gas as the rewards increase
        const txResponse = await contractCreate.execute(client);
        const receipt = await txResponse.getReceipt(client);
        const newContractId = receipt.contractId;

        console.log(`Rewards: ${rewardAddresses} @ ${rewardMultipliers}`);
        console.log(`RewarderViaMultiplierForPangoChef deployed at: ${newContractId.toString()} (0x${newContractId.toSolidityAddress()})`);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
