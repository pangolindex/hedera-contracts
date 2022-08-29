const { Client, AccountBalanceQuery, Hbar, ContractFunctionParameters, ContractExecuteTransaction, ContractCreateFlow, AccountId } = require("@hashgraph/sdk");
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
    const contractName = "WHBAR";

    console.log("Deploying " + contractName + " contract.");

    // Get the contract bytecode from Hardhat.
    const factory = await ethers.getContractFactory(contractName);
    const bytecode = factory.bytecode;
    // Create the deploy transaction.
    const contractCreateTransaction = new ContractCreateFlow()
        .setGas(2_000_000)
        .setInitialBalance(new Hbar(40))
        .setBytecode(bytecode);
    // Sign the transaction with the client operator key and submit to a Hedera network.
    const contractCreateTxResponse = contractCreateTransaction.execute(client);
    // Get the receipt of the transaction.
    const contractCreateTxReceipt = (await contractCreateTxResponse).getReceipt(client);
    // Get the new contract ID.
    const whbarContractId = (await contractCreateTxReceipt).contractId;
    console.log("The new " + contractName + " contract ID is " + whbarContractId + ". Make a record of it!");

    //Create the transaction for deposit
    const depositTransaction = new ContractExecuteTransaction()
        .setContractId(whbarContractId)
        .setGas(300_000)
        .setFunction("deposit")
        .setPayableAmount(1)
    //Sign with the client operator private key to pay for the transaction and submit the query to a Hedera network
    const depositTxResponse = await depositTransaction.execute(client);
    //Request the receipt of the transaction
    const depositTxReceipt = await depositTxResponse.getReceipt(client);
    //Get the transaction consensus status
    const depositTxStatus = depositTxReceipt.status;
    console.log("The deposit transaction consensus status is " +depositTxStatus);

    //Create the transaction for withdraw
    const withdrawTransaction = new ContractExecuteTransaction()
        .setContractId(whbarContractId)
        .setGas(300_000)
        .setFunction("withdraw", new ContractFunctionParameters()
            .addUint256(100000000)
        )
    //Sign with the client operator private key to pay for the transaction and submit the query to a Hedera network
    const withdrawTxResponse = await withdrawTransaction.execute(client);
    //Request the receipt of the transaction
    const withdrawTxReceipt = await withdrawTxResponse.getReceipt(client);
    //Get the transaction consensus status
    const withdrawTxStatus = withdrawTxReceipt.status;
    console.log("The withdraw transaction consensus status is " +withdrawTxStatus);

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
