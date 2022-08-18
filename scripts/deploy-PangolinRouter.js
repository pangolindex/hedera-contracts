const { Client, AccountBalanceQuery, ContractFunctionParameters, ContractCreateFlow, AccountId } = require("@hashgraph/sdk");
const { ethers } = require("hardhat");

require("dotenv").config();

async function main() {

    //Grab your Hedera testnet account ID and private key from your .env file
    const myAccountId = process.env.MY_ACCOUNT_ID;
    const myPrivateKey = process.env.MY_PRIVATE_KEY;
    const factoryId = process.env.FACTORY_CONTRACT_ID;
    const whbarId = process.env.WHBAR_CONTRACT_ID;

    // If we weren't able to grab it, we should throw a new error
    if (myAccountId == null || myPrivateKey == null || whbarId == null || factoryId == null) {
        throw new Error("Environment variables myAccountId, myPrivateKey, whbarId, and factoryId must be present");
    }

    // Create our connection to the Hedera network
    // The Hedera JS SDK makes this really easy!
    const client = Client.forTestnet();

    client.setOperator(myAccountId, myPrivateKey);

    /* ********************** *
     * DEPLOY PANGOLIN ROUTER *
     * ********************** */

    // Get the contract factory name.
    const contractName = "PangolinRouter";

    console.log("Deploying " + contractName + " contract.");

    // Set factory and whbar addresses.
    const factoryAddress = "0x".concat(AccountId.fromString(factoryId).toSolidityAddress());
    const whbarAddress = "0x".concat(AccountId.fromString(whbarId).toSolidityAddress());

    // Get the contract bytecode from Hardhat.
    const factory = await ethers.getContractFactory(contractName);
    const bytecode = factory.bytecode;

    // Create the deploy transaction.
    const contractCreate = new ContractCreateFlow()
        .setGas(100000)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(factoryAddress)
                .addAddress(whbarAddress)
        )
        .setBytecode(bytecode);

    // Sign the transaction with the client operator key and submit to a Hedera network.
    const txResponse = contractCreate.execute(client);

    // Get the receipt of the transaction.
    const receipt = (await txResponse).getReceipt(client);

    // Get the new contract ID.
    const newContractId = (await receipt).contractId;

    console.log("The new " + contractName + " contract ID is " + newContractId + ". Make a record of it!");

    // Get remaining account balance.
    const accountBalance = await new AccountBalanceQuery()
         .setAccountId(myAccountId)
         .execute(client);

    console.log("The new account balance is: " + accountBalance.hbars.toTinybars() + " tinybar.");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
