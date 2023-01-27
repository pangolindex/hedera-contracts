const { Client, ContractFunctionParameters, ContractCreateFlow, AccountId } = require("@hashgraph/sdk");
const { ethers } = require("hardhat");

require("dotenv").config();

// Fill these variables
const owners = [
    `0x${AccountId.fromString(process.env.MY_ACCOUNT_ID).toSolidityAddress()}`, // Ease of use hacky
];
const requiredConfirmations = 1;

async function main() {
    const myAccountId = process.env.MY_ACCOUNT_ID;
    const myPrivateKey = process.env.MY_PRIVATE_KEY;

    if (myAccountId == null || myPrivateKey == null) {
        throw new Error("Environment variables MY_ACCOUNT_ID and MY_PRIVATE_KEY must be present");
    }

    const client = Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    const Contract = await ethers.getContractFactory("MultiSigWallet");

    console.log(`Deploying MultiSigWallet ...`);
    const deployMultisigTx = await new ContractCreateFlow()
        .setBytecode(Contract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddressArray(owners)
                .addUint256(requiredConfirmations)
        )
        .setGas(200_000 + (100_000 * owners.length)) // Depends on initial signers
        .execute(client);
    const deployMultisigRx = await deployMultisigTx.getReceipt(client);
    const multisigId = deployMultisigRx.contractId;
    const multisigAddress = `0x${AccountId.fromString(multisigId).toSolidityAddress()}`;
    console.log(`MultiSigWallet ${multisigId} (${multisigAddress})`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

