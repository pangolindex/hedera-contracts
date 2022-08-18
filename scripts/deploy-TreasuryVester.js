const { Client, AccountBalanceQuery, Hbar, ContractFunctionParameters, ContractCreateFlow, AccountId } = require("@hashgraph/sdk");
const { ethers } = require("hardhat");

require("dotenv").config();

async function main() {

    //Grab your Hedera testnet account ID and private key from your .env file
    const myAccountId = process.env.MY_ACCOUNT_ID;
    const myPrivateKey = process.env.MY_PRIVATE_KEY;
    const multisigAccountId = process.env.MULTISIG_ACCOUNT_ID;

    // If we weren't able to grab it, we should throw a new error
    if (myAccountId == null || myPrivateKey == null || multisigAccountId == null) {
        throw new Error("Environment variables myAccountId, myPrivateKey, and multisigAccountId must be present");
    }

    // Create our connection to the Hedera network
    // The Hedera JS SDK makes this really easy!
    const client = Client.forTestnet();

    client.setOperator(myAccountId, myPrivateKey);

    /* *********************** *
     * DEPLOY PANGOLIN FACTORY *
     * *********************** */

    // Get the contract factory name.
    const contractName = "TreasuryVester";

    console.log("Deploying " + contractName + " contract.");

    // Use DAO multisig as the admin.
    const admin = "0x".concat(AccountId.fromString(multisigAccountId).toSolidityAddress());

    // Get the contract bytecode from Hardhat.
    const factory = await ethers.getContractFactory(contractName);
    const bytecode = factory.bytecode;

    // Create the deploy transaction.
    const contractCreate = new ContractCreateFlow()
        .setGas(2_000_000)
        .setInitialBalance(new Hbar(40))
        .setConstructorParameters(
            new ContractFunctionParameters().addAddress(admin)
        )
        .setBytecode(bytecode);

    // Sign the transaction with the client operator key and submit to a Hedera network.
    const txResponse = contractCreate.execute(client);

    // Get the receipt of the transaction.
    const receipt = (await txResponse).getReceipt(client);

    // Get the new contract ID.
    const newContractId = (await receipt).contractId;

    console.log("The new " + contractName + " contract ID is " + newContractId + ". Make a record of it!");
    console.log("Check an explorer for the associated tokens of the contract to find and record PNG token ID as well.");

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

