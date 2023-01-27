const { AccountId, Client, ContractCreateFlow, ContractFunctionParameters} = require('@hashgraph/sdk');
const { ethers } = require('hardhat');
require('dotenv').config({ path: '../.env' });


// Change these variables
const pangoChefAddress = '0x0000000000000000000000000000000000000750';
const rewardTokensAddresses = [
    '0x0',
];
const rewardTokenMultipliers = [
    1e8,
];


async function main() {

    if (rewardTokensAddresses.length !== rewardTokenMultipliers.length) throw new Error(`Mismatched arguments length`);
    if (!ethers.utils.isAddress(pangoChefAddress) || parseInt(pangoChefAddress, 16) === 0) throw new Error(`Invalid PangoChef address`);
    if (rewardTokensAddresses.some(addr => !ethers.utils.isAddress(addr) || parseInt(addr, 16) === 0)) throw new Error(`Invalid reward address`);

    const myAccountId = process.env.MY_ACCOUNT_ID;
    const myPrivateKey = process.env.MY_PRIVATE_KEY;

    if (myAccountId == null || myPrivateKey == null) {
        throw new Error('Environment variables MY_ACCOUNT_ID and MY_PRIVATE_KEY must be present');
    }

    const client = Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    // Get the contract factory name.
    const contractName = 'RewarderViaMultiplierForPangoChef';

    console.log('Deploying ' + contractName + ' contract.');

    // Get the contract bytecode from Hardhat.
    const factory = await ethers.getContractFactory(contractName);
    const bytecode = factory.bytecode;

    // Create the deploy transaction.
    const contractCreate = new ContractCreateFlow()
        .setBytecode(bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddressArray(rewardTokensAddresses) // rewardTokens
                .addUint256Array(rewardTokenMultipliers) // rewardMultipliers
                .addUint256(8) // baseRewardTokenDecimals
                .addAddress(pangoChefAddress) // chef
        )
        .setGas(1_000_000); // 853,234 - might need more gas as the rewards increase
    const txResponse = await contractCreate.execute(client);
    const receipt = await txResponse.getReceipt(client);
    const newContractId = receipt.contractId;

    console.log(`${contractName} deployed at: ${newContractId} (0x${AccountId.fromString(newContractId).toSolidityAddress()})`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
