const { Client, ContractFunctionParameters, ContractCreateFlow, AccountId } = require('@hashgraph/sdk');
const { ethers } = require('hardhat');
const path = require('node:path');

require('dotenv').config({
    path: path.resolve(__dirname, '..', '..', '.env'),
});

async function main() {
    const myAccountId = process.env.MY_ACCOUNT_ID;
    if (!myAccountId) throw new Error(`Missing MY_ACCOUNT_ID`);

    const myPrivateKey = process.env.MY_PRIVATE_KEY;
    if (!myPrivateKey) throw new Error(`Missing MY_PRIVATE_KEY`);

    let timelockId = process.env.TIMELOCK_ID;

    const timelockDelay = process.env.TIMELOCK_DELAY ?? (86_400 * 2);
    const proposalThreshold = process.env.PROPOSAL_THRESHOLD ?? (2_000_000e8);
    const proposalThresholdMin = process.env.PROPOSAL_THRESHOLD_MIN ?? (500_000e8);
    const proposalThresholdMax = process.env.PROPOSAL_THRESHOLD_MAX ?? (50_000_000e8);

    const stakingContractId = process.env.STAKING_CONTRACT_ID;
    if (!stakingContractId) throw new Error(`Missing STAKING_CONTRACT_ID`);

    const stakingNftId = process.env.STAKING_NFT_ID;
    if (!stakingNftId) throw new Error(`Missing STAKING_NFT_ID`);

    const client = process.env.NETWORK === 'mainnet' ? Client.forMainnet() : Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    const timelockContract = await ethers.getContractFactory('Timelock');
    const governorContract = await ethers.getContractFactory('GovernorPango');

    console.log('-- Timelock --');
    if (!timelockId) {
        console.log(`Admin:       ${myAccountId}`);
        console.log(`Delay (sec): ${timelockDelay}`);

        console.log('Deploying Timelock contract ...');
        const timelockTx = await new ContractCreateFlow()
            .setBytecode(timelockContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(AccountId.fromString(myAccountId).toSolidityAddress()) // admin
                    .addUint256(timelockDelay) // delay
            )
            .setGas(115_000) // ~98,361
            .execute(client);
        const timelockRx = await timelockTx.getReceipt(client);
        console.log(`Deployed Timelock at ${timelockId} (0x${timelockRx.contractId.toSolidityAddress()})`);
        timelockId = timelockRx.contractId.toString();
    } else {
        console.log(`Using existing Timelock of ${timelockId}`);
    }

    console.log();

    console.log('-- GovernorPango --');
    console.log(`Timelock:               ${timelockId}`);
    console.log(`Staking NFT:            ${stakingNftId}`);
    console.log(`Staking Contract:       ${stakingContractId}`);
    console.log(`Proposal Threshold:     ${proposalThreshold}`);
    console.log(`Proposal Threshold Min: ${proposalThresholdMin}`);
    console.log(`Proposal Threshold Max: ${proposalThresholdMax}`);

    console.log(`Deploying GovernorPango ...`);
    const governorTx = await new ContractCreateFlow()
        .setBytecode(governorContract.bytecode)
        .setConstructorParameters(new ContractFunctionParameters()
            .addAddress(AccountId.fromString(timelockId).toSolidityAddress()) // timelock
            .addAddress(AccountId.fromString(stakingNftId).toSolidityAddress()) // PangolinStakingPositions HTS NFT
            .addAddress(AccountId.fromString(stakingContractId).toSolidityAddress()) // PangolinStakingPositions contract
            .addUint96(proposalThreshold)
            .addUint96(proposalThresholdMin)
            .addUint96(proposalThresholdMax)
        )
        .setGas(100_000) // ~81,418
        .execute(client);
    const governorRx = await governorTx.getReceipt(client);
    const governorId = governorRx.contractId;
    const governorAddress = `0x${governorId.toSolidityAddress()}`;
    console.log(`Deployed GovernorPango: ${governorId} (${governorAddress})`);

    console.log('Done!');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
