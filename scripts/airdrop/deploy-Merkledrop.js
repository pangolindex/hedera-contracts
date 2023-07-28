const { AccountId, Client, ContractCreateFlow, ContractFunctionParameters } = require('@hashgraph/sdk');
const { ethers } = require('hardhat');
require('dotenv').config({ path: '../../.env' });

async function main() {
    const myAccountId = process.env.MY_ACCOUNT_ID;
    const myPrivateKey = process.env.MY_PRIVATE_KEY;

    if (!myAccountId || !myPrivateKey) {
        throw new Error('Environment variables MY_ACCOUNT_ID and MY_PRIVATE_KEY must be present');
    }

    const multisigId = process.env.MULTISIG_ACCOUNT_ID;
    if (!multisigId) throw new Error('Environment variable MULTISIG_ACCOUNT_ID must be present');

    const pbarHtsId = process.env.PBAR_HTS_ID;
    if (!pbarHtsId) throw new Error('Environment variable PBAR_HTS_ID must be present');

    const client = process.env.NETWORK === 'mainnet' ? Client.forMainnet() : Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    const contractName = 'Merkledrop';

    const factory = await ethers.getContractFactory(contractName);
    const bytecode = factory.bytecode;

    console.log(`Deploying ${contractName} contract ...`);

    // Create the deploy transaction.
    const deployTx = await new ContractCreateFlow()
        .setBytecode(bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(AccountId.fromString(pbarHtsId).toSolidityAddress())
                .addAddress(AccountId.fromString(multisigId).toSolidityAddress())
        )
        .setGas(900_000) // ~792,735
        .execute(client);
    const receipt = await deployTx.getReceipt(client);
    const newContractId = receipt.contractId;

    console.log(`The new ${contractName} contract ID is ${newContractId}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
