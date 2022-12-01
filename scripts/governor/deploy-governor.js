const { Client, ContractFunctionParameters, ContractCreateFlow, AccountId } = require('@hashgraph/sdk');
const { ethers } = require('hardhat');

require('dotenv').config();

async function main() {
    const myAccountId = process.env.MY_ACCOUNT_ID;
    if (!myAccountId) throw new Error(`Missing MY_ACCOUNT_ID`);

    const myPrivateKey = process.env.MY_PRIVATE_KEY;
    if (!myPrivateKey) throw new Error(`Missing MY_PRIVATE_KEY`);

    const timelockDelay = process.env.TIMELOCK_DELAY;
    if (!timelockDelay) throw new Error(`Missing TIMELOCK_DELAY`);

    const stakingContractId = process.env.STAKING_CONTRACT_ID;
    if (!stakingContractId) throw new Error(`Missing STAKING_CONTRACT_ID`);

    const stakingNftId = process.env.STAKING_NFT_ID;
    if (!stakingNftId) throw new Error(`Missing STAKING_NFT_ID`);

    const client = Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    // Get contracts
    const timelockContract = await ethers.getContractFactory('Timelock');
    const governorContract = await ethers.getContractFactory('Governor');
    const governorAssistantContract = await ethers.getContractFactory('GovernorAssistant');

    console.log('Deploying Timelock contract ...');
    const timelockTx = await new ContractCreateFlow()
        .setBytecode(timelockContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(AccountId.fromString(myAccountId).toSolidityAddress()) // admin
                .addUint256(timelockDelay) // delay
        )
        .setGas(100000)
        .execute(client);
    const timelockRx = await timelockTx.getReceipt(client);
    const timelockId = timelockRx.contractId;
    const timelockAddress = `0x${AccountId.fromString(timelockId).toSolidityAddress()}`;
    console.log(`Deployed Timelock at ${timelockId} (${timelockAddress})`);

    console.log(`Deploying GovernorAssistant ...`);
    const governorAssistantTx = await new ContractCreateFlow()
        .setBytecode(governorAssistantContract.bytecode)
        .setGas(100000)
        .execute(client);
    const governorAssistantRx = await governorAssistantTx.getReceipt(client);
    const governorAssistantId = governorAssistantRx.contractId;
    const governorAssistantAddress = `0x${AccountId.fromString(governorAssistantId).toSolidityAddress()}`;
    console.log(`Deployed GovernorAssistant: ${governorAssistantId} (${governorAssistantAddress})`);

    console.log(`Deploying Governor ...`);
    const governorTx = await new ContractCreateFlow()
        .setBytecode(governorContract.bytecode)
        .setConstructorParameters(new ContractFunctionParameters()
            .addAddress(AccountId.fromString(governorAssistantId).toSolidityAddress()) // assistant
            .addAddress(AccountId.fromString(timelockId).toSolidityAddress()) // timelock
            .addAddress(AccountId.fromString(stakingNftId).toSolidityAddress()) // PangolinStakingPositions HTS NFT
            .addAddress(AccountId.fromString(stakingContractId).toSolidityAddress()) // PangolinStakingPositions contract
        )
        .setGas(100000)
        .execute(client);
    const governorRx = await governorTx.getReceipt(client);
    const governorId = governorRx.contractId;
    const governorAddress = `0x${AccountId.fromString(governorId).toSolidityAddress()}`;
    console.log(`Deployed Governor: ${governorId} (${governorAddress})`);

    console.log('Done!');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
