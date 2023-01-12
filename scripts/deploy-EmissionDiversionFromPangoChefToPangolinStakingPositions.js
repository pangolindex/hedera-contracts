const { Client, ContractFunctionParameters, ContractCreateFlow, AccountId, ContractExecuteTransaction } = require("@hashgraph/sdk");
const { ethers } = require("hardhat");

require("dotenv").config();

// Fill these variables
const pangoChefAddress = "0x0";
const pangolinStakingPositionsAddress = "0x0";

async function main() {
    const myAccountId = process.env.MY_ACCOUNT_ID;
    const myPrivateKey = process.env.MY_PRIVATE_KEY;

    if (myAccountId == null || myPrivateKey == null) {
        throw new Error("Environment variables myAccountId and myPrivateKey must be present");
    }

    const client = Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    const Contract = await ethers.getContractFactory("EmissionDiversionFromPangoChefToPangolinStakingPositions");

    console.log(`Deploying EmissionDiversionFromPangoChefToPangolinStakingPositions ...`);
    const deployTx = await new ContractCreateFlow()
        .setGas(950_000) // 793,453
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pangoChefAddress)
                .addAddress(pangolinStakingPositionsAddress)
        )
        .setBytecode(Contract.bytecode)
        .execute(client);
    const deployRx = await deployTx.getReceipt(client);
    const newContractId = deployRx.contractId;
    const newContractAddress = `0x${AccountId.fromString(newContractId).toSolidityAddress()}`;
    console.log(`EmissionDiversionFromPangoChefToPangolinStakingPositions ${newContractId} (${newContractAddress})`);

    console.log(`Approving ...`);
    const approvalTx = await new ContractExecuteTransaction()
        .setContractId(newContractId)
        .setFunction('approve')
        .setGas(900_000) // 732,126
        .execute(client);
    const approvalRx = await approvalTx.getReceipt(client);
    console.log(`Approval succeeded`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

