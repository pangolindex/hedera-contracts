const { Client, ContractFunctionParameters, ContractCreateFlow, AccountId } = require('@hashgraph/sdk');
const { ethers } = require('hardhat');

require('dotenv').config();

async function main() {

    // Initialize environment
    const myAccountId = process.env.MY_ACCOUNT_ID;
    if (!myAccountId) throw new Error(`Missing MY_ACCOUNT_ID`);

    const myPrivateKey = process.env.MY_PRIVATE_KEY;
    if (!myPrivateKey) throw new Error(`Missing MY_PRIVATE_KEY`);

    const timelockDelay = process.env.TIMELOCK_DELAY;
    if (!timelockDelay) throw new Error(`Missing TIMELOCK_DELAY`);

    const proposerThreshold = process.env.GOVERNOR_PROPOSER_THRESHOLD;
    if (!proposerThreshold) throw new Error(`Missing GOVERNOR_PROPOSER_THRESHOLD`);

    const stakingContractId = process.env.STAKING_CONTRACT_ID;
    if (!stakingContractId) throw new Error(`Missing STAKING_CONTRACT_ID`);

    const stakingNftId = process.env.STAKING_NFT_ID;
    if (!stakingNftId) throw new Error(`Missing STAKING_NFT_ID`);
    

    const client = Client.forTestnet();
    client.setOperator(myAccountId, myPrivateKey);

    // Get contracts
    const timelockContract = await ethers.getContractFactory('Timelock');
    const nftVaultContract = await ethers.getContractFactory('NftVotingVault');
    const governorContract = await ethers.getContractFactory('LockedNFTGovernor');

    console.log('Deploying Timelock contract ...');
    const timelockTx = await new ContractCreateFlow()
        .setBytecode(timelockContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(AccountId.fromString(myAccountId).toSolidityAddress()) // admin
                .addUint256(timelockDelay) // delay
        )
        .setGas(2000000)
        .execute(client);
    const timelockRx = await timelockTx.getReceipt(client);
    const timelockId = timelockRx.contractId;
    const timelockAddress = `0x${AccountId.fromString(timelockId).toSolidityAddress()}`;
    console.log(`Deployed Timelock at ${timelockId} (${timelockAddress})`);

    console.log(`Deploying NftVotingVault ...`);
    const votingVaultTx = await new ContractCreateFlow()
        .setBytecode(nftVaultContract.bytecode)
        .setConstructorParameters(new ContractFunctionParameters()
            .addAddress(AccountId.fromString(stakingContractId).toSolidityAddress()) // staking positions contract
            .addAddress(AccountId.fromString(stakingNftId).toSolidityAddress()) // staking positions token nft
        )
        .setInitialBalance(25)
        .setGas(8000000)
        .execute(client);
    const votingVaultRx = await votingVaultTx.getReceipt(client);
    const votingVaultId = votingVaultRx.contractId;
    const votingVaultAddress = `0x${AccountId.fromString(votingVaultId).toSolidityAddress()}`;
    console.log(`Deployed NftVotingVault: ${votingVaultId} (${votingVaultAddress})`);

    console.log(`Deploying Governor ...`);
    const governorTx = await new ContractCreateFlow()
        .setBytecode(governorContract.bytecode)
        .setConstructorParameters(new ContractFunctionParameters()
            .addAddress(timelockAddress) // timelock
            .addAddress(AccountId.fromString(myAccountId).toSolidityAddress()) // guardian
            .addUint256(proposerThreshold) // threshold
            .addAddress(votingVaultAddress) // nftVault
        )
        .setGas(8000000)
        .execute(client);
    const governorRx = await governorTx.getReceipt(client);
    const governorId = governorRx.contractId;
    console.log(`Deployed Governor: ${governorId}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
