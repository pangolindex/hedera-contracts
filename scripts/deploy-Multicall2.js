const { Client, AccountBalanceQuery, ContractCreateFlow } = require("@hashgraph/sdk");
const { ethers } = require("hardhat");

require("dotenv").config();

async function main() {

    const myAccountId = process.env.MY_ACCOUNT_ID;
    const myPrivateKey = process.env.MY_PRIVATE_KEY;

    if (myAccountId == null || myPrivateKey == null) {
        throw new Error("Environment variables MY_ACCOUNT_ID and MY_PRIVATE_KEY must be present");
    }

    const client = Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    // Get the contract factory name.
    const contractName = "Multicall2";

    console.log("Deploying " + contractName + " contract.");

    // Get the contract bytecode from Hardhat.
    const factory = await ethers.getContractFactory(contractName);
    const bytecode = factory.bytecode;

    // Create the deploy transaction.
    const contractCreate = new ContractCreateFlow()
        .setGas(200_000)
        .setBytecode(bytecode);
    const txResponse = await contractCreate.execute(client);
    const receipt = await txResponse.getReceipt(client);
    const newContractId = receipt.contractId;

    console.log(`The new ${contractName} contract ID is ${newContractId}. Make a record of it!`);

    // Get remaining account balance.
    const accountBalance = await new AccountBalanceQuery()
         .setAccountId(myAccountId)
         .execute(client);

    console.log(`The new account balance is: ${accountBalance.hbars.toTinybars()} tinybar.`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
