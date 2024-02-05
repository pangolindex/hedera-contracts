const {ethers} = require('hardhat');
const fs = require('node:fs');
const path = require('node:path');
const ROLES = require('./static/roles');
const {
    Client,
    AccountId,
    TokenId,
    TransactionId,
    ContractCreateFlow,
    Hbar,
    HbarUnit,
    ContractFunctionParameters,
    ContractCallQuery,
    AccountBalanceQuery,
    ContractExecuteTransaction,
    PrivateKey,
    AccountCreateTransaction,
    KeyList,
    TokenAssociateTransaction,
    ContractId,
} = require('@hashgraph/sdk');
require('dotenv').config({path: '../.env'});

// Shared global variables
let client;
let deployment;

async function main() {
    // Required environment variables
    const MY_ACCOUNT_ID = process.env.MY_ACCOUNT_ID;
    const MY_PRIVATE_KEY = process.env.MY_PRIVATE_KEY;

    if (MY_ACCOUNT_ID == null || MY_PRIVATE_KEY == null) {
        throw new Error('Environment variables MY_ACCOUNT_ID, and MY_PRIVATE_KEY must be present');
    }

    // Optional environment variables
    const HBAR_USD_PRICE = Number.parseFloat(process.env.HBAR_USD_PRICE || '0.07');
    const TIMELOCK_DELAY = eval(process.env.TIMELOCK_DELAY) ?? (86_400 * 2); // 2 days
    const PROPOSAL_THRESHOLD = eval(process.env.PROPOSAL_THRESHOLD) ?? (2_000_000e8);
    const PROPOSAL_THRESHOLD_MIN = eval(process.env.PROPOSAL_THRESHOLD_MIN) ?? (1_000_000e8);
    const PROPOSAL_THRESHOLD_MAX = eval(process.env.PROPOSAL_THRESHOLD_MAX) ?? (115_000_000e8);

    if (process.env.NETWORK === 'testnet') {
        client = Client.forTestnet();
        client.setOperator(MY_ACCOUNT_ID, MY_PRIVATE_KEY);
    } else if (process.env.NETWORK === 'mainnet') {
        client = Client.forMainnet();
        client.setOperator(MY_ACCOUNT_ID, MY_PRIVATE_KEY);
    } else {
        throw new Error(`Unknown NETWORK '${process.env.NETWORK}'`);
    }

    deployment = readPartialDeployment();
    if (Object.keys(deployment).length > 0) {
        console.log(`Continuing from partial deployment:`);
        console.log(deployment);
    }

    const wrappedNativeTokenContract = await ethers.getContractFactory('WHBAR');
    const communityTreasury = await ethers.getContractFactory('CommunityTreasury');
    const treasuryVesterContract = await ethers.getContractFactory('TreasuryVester');
    const pangolinFactoryContract = await ethers.getContractFactory('PangolinFactory');
    const pangolinRouterContract = await ethers.getContractFactory('PangolinRouter');
    const pangolinPairContract = await ethers.getContractFactory('PangolinPair');
    const pangolinPairInitHash = ethers.utils.keccak256(pangolinPairContract.bytecode);
    const pangoChefContract = await ethers.getContractFactory('PangoChef');
    const rewardFundingForwarderContract = await ethers.getContractFactory('RewardFundingForwarder');
    const EmissionDiversionFromPangoChefToPangolinStakingPositions = await ethers.getContractFactory('EmissionDiversionFromPangoChefToPangolinStakingPositions');
    const pangolinStakingPositionsContract = await ethers.getContractFactory('PangolinStakingPositions');
    const governorPango = await ethers.getContractFactory('GovernorPango');
    const timelock = await ethers.getContractFactory('Timelock');
    const multicall2 = await ethers.getContractFactory('Multicall2');

    console.log(`Using HBAR price of $${HBAR_USD_PRICE}`);
    console.log(`Init Hash: ${pangolinPairInitHash}`);

    const deployerAddress = `0x${AccountId.fromString(MY_ACCOUNT_ID).toSolidityAddress()}`;
    console.log(`Deployer: ${deployerAddress}`);

    const balanceBefore = await new AccountBalanceQuery()
        .setAccountId(MY_ACCOUNT_ID)
        .execute(client);

    let vestingBotAddress;
    if (deployment['Vesting Bot']) {
        vestingBotAddress = deployment['Vesting Bot'];
        console.log(`Vesting Bot: ${vestingBotAddress}`);
    } else {
        const vestingBotPrivateKey = PrivateKey.generateED25519();
        console.log(`Creating vesting bot with private key: ${vestingBotPrivateKey.toStringDer()} ...`);
        const newAccountTx = await new AccountCreateTransaction()
            .setKey(vestingBotPrivateKey.publicKey)
            .setInitialBalance(new Hbar(10))
            .execute(client);
        const newAccountRx = await newAccountTx.getReceipt(client);
        vestingBotAddress = `0x${newAccountRx.accountId.toSolidityAddress()}`;
        deployment['Vesting Bot'] = vestingBotAddress;
        deployment['Vesting Bot PK'] = vestingBotPrivateKey.toStringDer();
        writePartialDeployment();
        console.log(`Vesting Bot: ${vestingBotAddress}`);
    }

    // Multisig
    let multisigAddress;
    if (deployment['Multisig']) {
        multisigAddress = deployment['Multisig'];
        console.log(`Multisig: ${multisigAddress}`);
    } else {
        console.log(`Creating multisig with 1/1 threshold ...`);
        const createMultisigTx = await new AccountCreateTransaction()
            .setKey(new KeyList([client.operatorPublicKey], 1))
            .setInitialBalance(new Hbar(20))
            .execute(client);
        const createMultisigRx = await createMultisigTx.getReceipt(client);
        multisigAddress = `0x${createMultisigRx.accountId.toSolidityAddress()}`;
        deployment['Multisig'] = multisigAddress;
        writePartialDeployment();
        console.log(`Multisig: ${multisigAddress}`);
    }

    console.log('============================== DEPLOYMENT ==============================');

    // WHBAR
    let wrappedNativeTokenContractAddress;
    if (deployment['WHBAR (Contract)']) {
        wrappedNativeTokenContractAddress = deployment['WHBAR (Contract)'];
        console.log(`WHBAR (Contract): ${wrappedNativeTokenContractAddress}`);
    } else {
        const createWrappedNativeTokenTx = await new ContractCreateFlow()
            .setBytecode(wrappedNativeTokenContract.bytecode)
            .setGas(500_000)
            .setInitialBalance(new Hbar(Math.ceil(1.10 / HBAR_USD_PRICE))) // $1.00
            .execute(client);
        const createWrappedNativeTokenRx = await createWrappedNativeTokenTx.getReceipt(client);
        wrappedNativeTokenContractAddress = `0x${createWrappedNativeTokenRx.contractId.toSolidityAddress()}`;
        deployment['WHBAR (Contract)'] = wrappedNativeTokenContractAddress;
        writePartialDeployment();
        console.log(`WHBAR (Contract): ${wrappedNativeTokenContractAddress}`);
    }
    const wrappedNativeTokenContractId = AccountId.fromSolidityAddress(wrappedNativeTokenContractAddress).toString();

    // WHBAR HTS Address
    let wrappedNativeTokenHTSAddress;
    if (deployment['WHBAR (HTS)']) {
        wrappedNativeTokenHTSAddress = deployment['WHBAR (HTS)'];
        console.log(`WHBAR (HTS): ${wrappedNativeTokenHTSAddress}`);
    } else {
        const whbarQueryTx = await new ContractCallQuery()
            .setContractId(wrappedNativeTokenContractId)
            .setGas(25_000)
            .setFunction('TOKEN_ID')
            .execute(client);
        wrappedNativeTokenHTSAddress = `0x${whbarQueryTx.getAddress(0)}`;
        deployment['WHBAR (HTS)'] = wrappedNativeTokenHTSAddress;
        writePartialDeployment();
        console.log(`WHBAR (HTS): ${wrappedNativeTokenHTSAddress}`);
    }

    // Timelock
    let timelockAddress;
    if (deployment['Timelock']) {
        timelockAddress = deployment['Timelock'];
        console.log(`Timelock: ${timelockAddress}`);
    } else {
        const createTimelockTx = await new ContractCreateFlow()
            .setBytecode(timelock.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(deployerAddress) // admin
                    .addUint256(TIMELOCK_DELAY) // delay
            )
            .setGas(200_000)
            .execute(client);
        const createTimelockRx = await createTimelockTx.getReceipt(client);
        timelockAddress = `0x${createTimelockRx.contractId.toSolidityAddress()}`;
        deployment['Timelock'] = timelockAddress;
        writePartialDeployment();
        console.log(`Timelock: ${timelockAddress}`);
    }
    const timelockId = AccountId.fromSolidityAddress(timelockAddress).toString();

    // TreasuryVester
    let treasuryVesterAddress;
    if (deployment['TreasuryVester']) {
        treasuryVesterAddress = deployment['TreasuryVester'];
        console.log(`TreasuryVester: ${treasuryVesterAddress}`);
    } else {
        const createTreasuryVesterTx = await new ContractCreateFlow()
            .setBytecode(treasuryVesterContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(deployerAddress) // admin (deployer for now and will be set to Multisig later)
            )
            .setGas(1_200_000)
            .setInitialBalance(new Hbar(Math.ceil(1.10 / HBAR_USD_PRICE))) // $0.90
            .execute(client);
        const createTreasuryVesterRx = await createTreasuryVesterTx.getReceipt(client);
        treasuryVesterAddress = `0x${createTreasuryVesterRx.contractId.toSolidityAddress()}`;
        deployment['TreasuryVester'] = treasuryVesterAddress;
        writePartialDeployment();
        console.log(`TreasuryVester: ${treasuryVesterAddress}`);
    }
    const treasuryVesterId = AccountId.fromSolidityAddress(treasuryVesterAddress).toString();

    // PNG HTS Information
    let pngHTSAddress;
    if (deployment['PNG (HTS)']) {
        pngHTSAddress = deployment['PNG (HTS)'];
        console.log(`PNG (HTS): ${pngHTSAddress}`);
    } else {
        const pngQueryTx = await new ContractCallQuery()
            .setContractId(treasuryVesterId)
            .setGas(30_000)
            .setFunction('PNG')
            .execute(client);
        pngHTSAddress = `0x${pngQueryTx.getAddress(0)}`;
        deployment['PNG (HTS)'] = pngHTSAddress;
        writePartialDeployment();
        console.log(`PNG (HTS): ${pngHTSAddress}`);
    }

    // CommunityTreasury
    let communityTreasuryAddress;
    if (deployment['CommunityTreasury']) {
        communityTreasuryAddress = deployment['CommunityTreasury'];
        console.log(`CommunityTreasury: ${communityTreasuryAddress}`);
    } else {
        const createCommunityTreasuryTx = await new ContractCreateFlow()
            .setBytecode(communityTreasury.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(pngHTSAddress)
            )
            .setGas(1_000_000)
            .execute(client);
        const createCommunityTreasuryRx = await createCommunityTreasuryTx.getReceipt(client);
        communityTreasuryAddress = `0x${createCommunityTreasuryRx.contractId.toSolidityAddress()}`;
        deployment['CommunityTreasury'] = communityTreasuryAddress;
        writePartialDeployment();
        console.log(`CommunityTreasury: ${communityTreasuryAddress}`);
    }
    const communityTreasuryId = AccountId.fromSolidityAddress(communityTreasuryAddress).toString();

    // PangolinFactory
    let pangolinFactoryAddress;
    if (deployment['PangolinFactory']) {
        pangolinFactoryAddress = deployment['PangolinFactory'];
        console.log(`PangolinFactory: ${pangolinFactoryAddress}`);
    } else {
        const createPangolinFactoryTx = await new ContractCreateFlow()
            .setBytecode(pangolinFactoryContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(timelockAddress) // feeToSetter
            )
            .setGas(1_000_000)
            .execute(client);
        const createPangolinFactoryRx = await createPangolinFactoryTx.getReceipt(client);
        pangolinFactoryAddress = `0x${createPangolinFactoryRx.contractId.toSolidityAddress()}`;
        deployment['PangolinFactory'] = pangolinFactoryAddress;
        writePartialDeployment();
        console.log(`PangolinFactory: ${pangolinFactoryAddress}`);
    }
    const pangolinFactoryId = AccountId.fromSolidityAddress(pangolinFactoryAddress).toString();

    // PangolinRouter
    let pangolinRouterAddress;
    if (deployment['PangolinRouter']) {
        pangolinRouterAddress = deployment['PangolinRouter'];
        console.log(`PangolinRouter: ${pangolinRouterAddress}`);
    } else {
        const createPangolinRouterTx = await new ContractCreateFlow()
            .setBytecode(pangolinRouterContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(pangolinFactoryAddress) // factory
                    .addAddress(wrappedNativeTokenContractAddress) // whbar
            )
            .setGas(1_500_000)
            .execute(client);
        const createPangolinRouterRx = await createPangolinRouterTx.getReceipt(client);
        pangolinRouterAddress = `0x${createPangolinRouterRx.contractId.toSolidityAddress()}`;
        deployment['PangolinRouter'] = pangolinRouterAddress;
        writePartialDeployment();
        console.log(`PangolinRouter: ${pangolinRouterAddress}`);
    }

    // Create PNG/WHBAR as first pair (required for PangolinFactory creation)
    let firstPairAddress;
    if (deployment['Pair PNG/WHBAR (Contract)']) {
        firstPairAddress = deployment['Pair PNG/WHBAR (Contract)'];
        console.log(`Pair PNG/WHBAR (Contract): ${firstPairAddress}`);
    } else {
        const createFirstPairTx = await new ContractExecuteTransaction()
            .setContractId(pangolinFactoryId)
            .setFunction('createPair',
                new ContractFunctionParameters()
                    .addAddress(pngHTSAddress)
                    .addAddress(wrappedNativeTokenHTSAddress)
            )
            .setGas(3_500_000)
            .setPayableAmount(new Hbar(Math.ceil(1.10 / HBAR_USD_PRICE))) // $1.00
            .execute(client);
        const createFirstPairRx = await createFirstPairTx.getRecord(client);
        firstPairAddress = `0x${createFirstPairRx.contractFunctionResult.getAddress(0)}`;
        deployment['Pair PNG/WHBAR (Contract)'] = firstPairAddress;
        writePartialDeployment();
        console.log(`Pair PNG/WHBAR (Contract): ${firstPairAddress}`);
    }

    // PangoChef
    let pangoChefAddress;
    if (deployment['PangoChef']) {
        pangoChefAddress = deployment['PangoChef'];
        console.log(`PangoChef: ${pangoChefAddress}`);
    } else {
        const createPangoChefTx = await new ContractCreateFlow()
            .setBytecode(pangoChefContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(pngHTSAddress) // newRewardsToken
                    .addAddress(deployerAddress) // newAdmin (deployer for now and will be set to Multisig later)
                    .addAddress(pangolinFactoryAddress) // newFactory
                    .addAddress(wrappedNativeTokenHTSAddress) // newWrappedNativeToken
            )
            .setGas(3_200_000)
            .execute(client);
        const createPangoChefRx = await createPangoChefTx.getReceipt(client);
        pangoChefAddress = `0x${createPangoChefRx.contractId.toSolidityAddress()}`;
        deployment['PangoChef'] = pangoChefAddress;
        writePartialDeployment();
        console.log(`PangoChef: ${pangoChefAddress}`);
    }
    const pangoChefId = AccountId.fromSolidityAddress(pangoChefAddress).toString();

    // RewardFundingForwarder (PangoChef)
    let pangoChefRewardFundingForwarderAddress;
    if (deployment['RewardFundingForwarder (PangoChef)']) {
        pangoChefRewardFundingForwarderAddress = deployment['RewardFundingForwarder (PangoChef)'];
        console.log(`RewardFundingForwarder (PangoChef): ${pangoChefRewardFundingForwarderAddress}`);
    } else {
        const createPangoChefRewardFundingForwarderTx = await new ContractCreateFlow()
            .setBytecode(rewardFundingForwarderContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(pangoChefAddress) // pangoChef
            )
            .setGas(1_000_000)
            .execute(client);
        const createPangoChefRewardFundingForwarderRx = await createPangoChefRewardFundingForwarderTx.getReceipt(client);
        pangoChefRewardFundingForwarderAddress = `0x${createPangoChefRewardFundingForwarderRx.contractId.toSolidityAddress()}`;
        deployment['RewardFundingForwarder (PangoChef)'] = pangoChefRewardFundingForwarderAddress;
        writePartialDeployment();
        console.log(`RewardFundingForwarder (PangoChef): ${pangoChefRewardFundingForwarderAddress}`);
    }
    const pangoChefRewardFundingForwarderId = AccountId.fromSolidityAddress(pangoChefRewardFundingForwarderAddress).toString();

    // PangolinStakingPositions
    let pangolinStakingPositionsAddress;
    if (deployment['PangolinStakingPositions']) {
        pangolinStakingPositionsAddress = deployment['PangolinStakingPositions'];
        console.log(`PangolinStakingPositions: ${pangolinStakingPositionsAddress}`);
    } else {
        const createPangolinStakingPositionsTx = await new ContractCreateFlow()
            .setBytecode(pangolinStakingPositionsContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(pngHTSAddress) // newRewardsToken
                    .addAddress(deployerAddress) // newAdmin (deployer for now and will be set to Multisig later)
            )
            .setGas(2_000_000)
            .setInitialBalance(new Hbar(Math.ceil(1.10 / HBAR_USD_PRICE))) // $0.95
            .execute(client);
        const createPangolinStakingPositionsRx = await createPangolinStakingPositionsTx.getReceipt(client);
        pangolinStakingPositionsAddress = `0x${createPangolinStakingPositionsRx.contractId.toSolidityAddress()}`;
        deployment['PangolinStakingPositions'] = pangolinStakingPositionsAddress;
        writePartialDeployment();
        console.log(`PangolinStakingPositions: ${pangolinStakingPositionsAddress}`);
    }
    const pangolinStakingPositionsId = AccountId.fromSolidityAddress(pangolinStakingPositionsAddress).toString();

    // Pangolin Staking Positions NFT HTS Information
    let pangolinStakingPositionsHTSAddress;
    if (deployment['SSS NFT (HTS)']) {
        pangolinStakingPositionsHTSAddress = deployment['SSS NFT (HTS)'];
            console.log(`SSS NFT (HTS): ${pangolinStakingPositionsHTSAddress}`);
    } else {
        const positionsTokenQueryTx = await new ContractCallQuery()
            .setContractId(pangolinStakingPositionsId)
            .setGas(30_000)
            .setFunction('positionsToken')
            .execute(client);
        pangolinStakingPositionsHTSAddress = `0x${positionsTokenQueryTx.getAddress(0)}`;
        deployment['SSS NFT (HTS)'] = pangolinStakingPositionsHTSAddress;
        writePartialDeployment();
        console.log(`SSS NFT (HTS): ${pangolinStakingPositionsHTSAddress}`);
    }

    // EmissionDiversionFromPangoChefToPangolinStakingPositions
    let emissionDiversionFromPangoChefToPangolinStakingPositionsAddress;
    if (deployment['EmissionDiversionFromPangoChefToPangolinStakingPositions']) {
        emissionDiversionFromPangoChefToPangolinStakingPositionsAddress = deployment['EmissionDiversionFromPangoChefToPangolinStakingPositions'];
        console.log(`EmissionDiversionFromPangoChefToPangolinStakingPositions: ${emissionDiversionFromPangoChefToPangolinStakingPositionsAddress}`);
    } else {
        const createEmissionDiversionFromPangoChefToPangolinStakingPositionsTx = await new ContractCreateFlow()
            .setBytecode(EmissionDiversionFromPangoChefToPangolinStakingPositions.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(pangoChefAddress)
                    .addAddress(pangolinStakingPositionsAddress)
            )
            .setGas(1_500_000)
            .execute(client);
        const createEmissionDiversionFromPangoChefToPangolinStakingPositionsRx = await createEmissionDiversionFromPangoChefToPangolinStakingPositionsTx.getReceipt(client);
        emissionDiversionFromPangoChefToPangolinStakingPositionsAddress = `0x${createEmissionDiversionFromPangoChefToPangolinStakingPositionsRx.contractId.toSolidityAddress()}`;
        deployment['EmissionDiversionFromPangoChefToPangolinStakingPositions'] = emissionDiversionFromPangoChefToPangolinStakingPositionsAddress;
        writePartialDeployment();
        console.log(`EmissionDiversionFromPangoChefToPangolinStakingPositions: ${emissionDiversionFromPangoChefToPangolinStakingPositionsAddress}`);
    }
    const emissionDiversionFromPangoChefToPangolinStakingPositionsId = AccountId.fromSolidityAddress(emissionDiversionFromPangoChefToPangolinStakingPositionsAddress).toString();

    // GovernorPango
    let governorPangoAddress;
    if (deployment['GovernorPango']) {
        governorPangoAddress = deployment['GovernorPango'];
        console.log(`GovernorPango: ${governorPangoAddress}`);
    } else {
        const createGovernorPangoTx = await new ContractCreateFlow()
            .setBytecode(governorPango.bytecode)
            .setConstructorParameters(new ContractFunctionParameters()
                .addAddress(timelockAddress) // timelock
                .addAddress(pangolinStakingPositionsHTSAddress) // PangolinStakingPositions HTS NFT
                .addAddress(pangolinStakingPositionsAddress) // PangolinStakingPositions contract
                .addUint96(PROPOSAL_THRESHOLD) // proposal threshold
                .addUint96(PROPOSAL_THRESHOLD_MIN) // proposal threshold min
                .addUint96(PROPOSAL_THRESHOLD_MAX) // proposal threshold max
            )
            .setGas(500_000)
            .execute(client);
        const createGovernorPangoRx = await createGovernorPangoTx.getReceipt(client);
        governorPangoAddress = `0x${createGovernorPangoRx.contractId.toSolidityAddress()}`;
        deployment['GovernorPango'] = governorPangoAddress;
        writePartialDeployment();
        console.log(`GovernorPango: ${governorPangoAddress}`);
    }

    // Multicall2
    let multicall2Address;
    if (deployment['Multicall2']) {
        multicall2Address = deployment['Multicall2'];
        console.log(`Multicall2: ${multicall2Address}`);
    } else {
        const createMulticall2Tx = await new ContractCreateFlow()
            .setBytecode(multicall2.bytecode)
            .setGas(300_000)
            .execute(client);
        const createMulticall2Rx = await createMulticall2Tx.getReceipt(client);
        multicall2Address = `0x${createMulticall2Rx.contractId.toSolidityAddress()}`;
        deployment['Multicall2'] = multicall2Address;
        writePartialDeployment();
        console.log(`Multicall2: ${multicall2Address}`);
    }

    console.log('============================== CONFIGURATION: MULTISIG ==============================');

    // Ensure 'config' map exists
    if (!deployment.config) {
        deployment.config = {};
    }

    if (!deployment.config['Associate Multisig Tokens']) {
        const associateTokensMultisigTx = await new TokenAssociateTransaction()
            .setAccountId(AccountId.fromSolidityAddress(multisigAddress))
            .setTokenIds([
                TokenId.fromSolidityAddress(pngHTSAddress),
                TokenId.fromSolidityAddress(wrappedNativeTokenHTSAddress),
                TokenId.fromSolidityAddress(pangolinStakingPositionsHTSAddress),
            ])
            .setTransactionId(TransactionId.generate(AccountId.fromSolidityAddress(multisigAddress)))
            .execute(client);
        const associateTokensMultisigRx = await associateTokensMultisigTx.getReceipt(client);
        deployment.config['Associate Multisig Tokens'] = true;
        writePartialDeployment();
        console.log(`Associated PBAR, WHBAR, and SSS to multisig`);
    }

    console.log('============================== CONFIGURATION: TIMELOCK ==============================');

    const queuePendingAdmin_bytes = new ContractFunctionParameters().addAddress(governorPangoAddress)._build();

    if (!deployment.config['Queue Timelock Admin Change']) {
        const queuePendingAdmin_eta = Math.ceil(Date.now() / 1000) + TIMELOCK_DELAY + 30;

        const queuePendingAdminTx = await new ContractExecuteTransaction()
            .setContractId(timelockId)
            .setFunction('queueTransaction',
                new ContractFunctionParameters()
                    .addAddress(timelockAddress) // target
                    .addUint256(0) // value
                    .addString('setPendingAdmin(address)') // signature
                    .addBytes(queuePendingAdmin_bytes) // data
                    .addUint256(queuePendingAdmin_eta) // eta
            )
            .setGas(1_500_000)
            .execute(client);
        const queuePendingAdminRx = await queuePendingAdminTx.getReceipt(client);
        deployment.config['Queue Timelock Admin Change'] = true;
        deployment.config['Queue Timelock Admin Change ETA'] = queuePendingAdmin_eta;
        writePartialDeployment();
        console.log(`Queued GovernorPango as pending Timelock admin`);
    }

    if (process.env.NETWORK === 'testnet') {
        if (!deployment.config['Execute Timelock Admin Change']) {
            const eta = deployment.config['Queue Timelock Admin Change ETA'];
            const waitTimeMs = eta - Date.now();

            if (waitTimeMs > 0) {
                console.log(`Waiting for timelock delay of ${(waitTimeMs / 1000).toFixed()} seconds ...`);
                await new Promise(resolve => setTimeout(resolve, waitTimeMs));
            }

            const executePendingAdminTx = await new ContractExecuteTransaction()
                .setContractId(timelockId)
                .setFunction('executeTransaction',
                    new ContractFunctionParameters()
                        .addAddress(timelockAddress) // target
                        .addUint256(0) // value
                        .addString('setPendingAdmin(address)') // signature
                        .addBytes(queuePendingAdmin_bytes) // data
                        .addUint256(eta) // eta
                )
                .setGas(150_000)
                .execute(client);
            const executePendingAdminRx = await executePendingAdminTx.getReceipt(client);
            deployment.config['Execute Timelock Admin Change'] = true;
            writePartialDeployment();
            console.log(`Executed GovernorPango as pending Timelock admin`);
        }

        if (!deployment.config['Accept Timelock Admin Change']) {
            const acceptAdminTx = await new ContractExecuteTransaction()
                .setContractId(ContractId.fromSolidityAddress(governorPangoAddress))
                .setFunction('__acceptAdmin')
                .setGas(150_000)
                .execute(client);
            const acceptAdminRx = await acceptAdminTx.getReceipt(client);
            deployment.config['Accept Timelock Admin Change'] = true;
            writePartialDeployment();
            console.log(`Accepted GovernorPango as Timelock admin`);
        }
    }

    console.log('============================== CONFIGURATION: COMMUNITY TREASURY ==============================');

    if (!deployment.config['Transfer Community Treasury Ownership']) {
        const transferOwnershipCommunityTreasuryTx = await new ContractExecuteTransaction()
            .setContractId(communityTreasuryId)
            .setFunction('transferOwnership',
                new ContractFunctionParameters()
                    .addAddress(timelockAddress)
            )
            .setGas(150_000)
            .execute(client);
        const transferOwnershipCommunityTreasuryRx = await transferOwnershipCommunityTreasuryTx.getReceipt(client);
        deployment.config['Transfer Community Treasury Ownership'] = true;
        writePartialDeployment();
        console.log('Transferred ownership of CommunityTreasury to Timelock');
    }

    console.log('============================== CONFIGURATION: TREASURY VESTER ==============================');

    const VESTER_ALLOCATIONS = [
        {
            // Community Treasury
            address: communityTreasuryAddress,
            allocation: 1569, // governance-owned treasury
        },
        {
            // Team
            address: multisigAddress,
            allocation: 1830, // multisig
        },
        {
            // Chef
            address: pangoChefRewardFundingForwarderAddress,
            allocation: 6601, // LPs & PNG Staking
        }
    ];
    const vesterAccounts = VESTER_ALLOCATIONS.map(({address}) => address);
    const vesterAllocations = VESTER_ALLOCATIONS.map(({allocation}) => allocation);

    if (!deployment.config['Set Vester Recipients']) {
        const setRecipientsTx = await new ContractExecuteTransaction()
            .setContractId(treasuryVesterId)
            .setFunction('setRecipients',
                new ContractFunctionParameters()
                    .addAddressArray(vesterAccounts) // accounts
                    .addInt64Array(vesterAllocations) // allocations
            )
            .setGas(300_000)
            .execute(client);
        const setRecipientsRx = await setRecipientsTx.getReceipt(client);
        deployment.config['Set Vester Recipients'] = true;
        writePartialDeployment();
        console.log(`Treasury vester recipients set`);
    }

    if (!deployment.config['Unpause Vester']) {
        const unpauseTreasuryVesterTx = await new ContractExecuteTransaction()
            .setContractId(treasuryVesterId)
            .setFunction('unpause')
            .setGas(100_000)
            .execute(client);
        const unpauseTreasuryVesterRx = await unpauseTreasuryVesterTx.getReceipt(client);
        deployment.config['Unpause Vester'] = true;
        writePartialDeployment();
        console.log(`Vesting un-paused`);
    }

    if (!deployment.config['Transfer Initial PBAR Supply to Multisig']) {
        const transferInitialSupplyTx = await new ContractExecuteTransaction()
            .setContractId(treasuryVesterId)
            .setFunction('transferInitialSupply',
                new ContractFunctionParameters()
                    .addAddress(multisigAddress)
            )
            .setGas(400_000)
            .execute(client);
        const transferInitialSupplyRx = await transferInitialSupplyTx.getReceipt(client);
        deployment.config['Transfer Initial PBAR Supply to Multisig'] = true;
        writePartialDeployment();
        console.log(`Transferred initial PBAR supply to multisig`);
    }

    await grantRole(treasuryVesterId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(treasuryVesterId, ROLES.DEFAULT_ADMIN_ROLE, deployerAddress);

    console.log('============================== CONFIGURATION: PANGOCHEF ==============================');

    if (!deployment.config['Approve PangoChefRewardFundingForwarder']) {
        const approvePangoChefRewardFundingForwarderTx = await new ContractExecuteTransaction()
            .setContractId(pangoChefRewardFundingForwarderId)
            .setFunction('approve')
            .setGas(1_500_000)
            .execute(client);
        const approvePangoChefRewardFundingForwarderRx = await approvePangoChefRewardFundingForwarderTx.getReceipt(client);
        deployment.config['Approve PangoChefRewardFundingForwarder'] = true;
        writePartialDeployment();
        console.log(`Setup approval for RewardFundingForwarder (PangoChef)`);
    }

    if (!deployment.config['Initialize Emission Diversion Farm']) {
        const initializeEmissionDiversionFarmTx = await new ContractExecuteTransaction()
            .setContractId(pangoChefId)
            .setFunction('initializePool',
                new ContractFunctionParameters()
                    .addAddress(emissionDiversionFromPangoChefToPangolinStakingPositionsAddress) // tokenOrRecipient
                    .addAddress('0x0000000000000000000000000000000000000000') // pairContract
                    .addUint8(2) // poolType
            )
            .setGas(400_000)
            .execute(client);
        const initializeEmissionDiversionFarmRx = await initializeEmissionDiversionFarmTx.getReceipt(client);
        deployment.config['Initialize Emission Diversion Farm'] = true;
        writePartialDeployment();
        console.log(`Initialized emission diversion farm`);
    }

    await grantRole(pangoChefId, ROLES.FUNDER_ROLE, vestingBotAddress);
    await grantRole(pangoChefId, ROLES.FUNDER_ROLE, pangoChefRewardFundingForwarderAddress);
    await grantRole(pangoChefId, ROLES.FUNDER_ROLE, multisigAddress);
    await grantRole(pangoChefId, ROLES.POOL_MANAGER_ROLE, multisigAddress);
    await grantRole(pangoChefId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(pangoChefId, ROLES.FUNDER_ROLE, deployerAddress);
    await renounceRole(pangoChefId, ROLES.POOL_MANAGER_ROLE, deployerAddress);
    await renounceRole(pangoChefId, ROLES.DEFAULT_ADMIN_ROLE, deployerAddress);

    console.log('============================== CONFIGURATION: STAKING POSITIONS ==============================');

    if (!deployment.config['Approval for EmissionDiversionFromPangoChefToPangolinStakingPositions']) {
        const approveEmissionDiversionFromPangoChefToPangolinStakingPositionsTx = await new ContractExecuteTransaction()
            .setContractId(emissionDiversionFromPangoChefToPangolinStakingPositionsId)
            .setFunction('approve')
            .setGas(1_500_000)
            .execute(client);
        const approveEmissionDiversionFromPangoChefToPangolinStakingPositionsRx = await approveEmissionDiversionFromPangoChefToPangolinStakingPositionsTx.getReceipt(client);
        deployment.config['Approval for EmissionDiversionFromPangoChefToPangolinStakingPositions'] = true;
        writePartialDeployment();
        console.log(`Setup approval for EmissionDiversionFromPangoChefToPangolinStakingPositions`);
    }

    await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, vestingBotAddress);
    await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, emissionDiversionFromPangoChefToPangolinStakingPositionsAddress);
    await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, multisigAddress);
    await grantRole(pangolinStakingPositionsId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, deployerAddress);
    await renounceRole(pangolinStakingPositionsId, ROLES.DEFAULT_ADMIN_ROLE, deployerAddress);

    writeFullDeployment();

    const balanceAfter = await new AccountBalanceQuery()
        .setAccountId(MY_ACCOUNT_ID)
        .execute(client);

    const balanceDelta = balanceBefore.hbars.toBigNumber().minus(balanceAfter.hbars.toBigNumber());
    console.log(`HBAR cost: ${Hbar.from(balanceDelta, HbarUnit.Hbar).toString()}`);
}

main()
    .then(() => {
        writeFullDeployment();
        process.exit(0);
    })
    .catch((error) => {
        console.error(error);
        writePartialDeployment();
        process.exit(1);
    });

function readPartialDeployment() {
    const outputDirectory = path.join(__dirname, '..', 'deployments');
    const partialFile = path.join(outputDirectory, `${process.env.NETWORK}@partial.json`);
    if (fs.existsSync(partialFile)) {
        const partialDeployment = fs.readFileSync(partialFile, {encoding: 'utf-8'});
        return JSON.parse(partialDeployment);
    } else {
        return {};
    }
}

function writePartialDeployment() {
    const outputDirectory = path.join(__dirname, '..', 'deployments');
    if (!fs.existsSync(outputDirectory)) {
        fs.mkdirSync(outputDirectory, {recursive: true});
    }
    const outputFile = path.join(outputDirectory, `${process.env.NETWORK}@partial.json`);
    fs.writeFileSync(outputFile, JSON.stringify(deployment), {encoding: 'utf-8'});
}

function writeFullDeployment() {
    const outputDirectory = path.join(__dirname, '..', 'deployments');
    if (!fs.existsSync(outputDirectory)) {
        fs.mkdirSync(outputDirectory, {recursive: true});
    }
    const fullDeploymentFilePath = path.join(outputDirectory, `${process.env.NETWORK}@${Date.now()}.json`);
    fs.writeFileSync(fullDeploymentFilePath, JSON.stringify(deployment), {encoding: 'utf-8'});
    console.log(`Saved deployment record to ${fullDeploymentFilePath}`);

    // Remove partial deployment
    const partialDeploymentFilePath = path.join(outputDirectory, `${process.env.NETWORK}@partial.json`);
    if (fs.existsSync(partialDeploymentFilePath)) {
        fs.unlinkSync(partialDeploymentFilePath);
        console.log(`Deleted partial deployment record from ${partialDeploymentFilePath}`);
    }
}

async function grantRole(contractId, roleHash, accountAddress) {
    const description = `Granting role ${contractId}:${roleHash} to ${accountAddress}`;

    if (!deployment.config[description]) {
        console.log(`${description} ...`);
        const grantRoleTx = await new ContractExecuteTransaction()
            .setContractId(contractId)
            .setFunction('grantRole',
                new ContractFunctionParameters()
                    .addBytes32(ethers.utils.arrayify(roleHash))
                    .addAddress(accountAddress)
            )
            .setGas(400_000)
            .execute(client);
        const grantRoleRx = await grantRoleTx.getReceipt(client);
        deployment.config[description] = true;
        writePartialDeployment();
        console.log(`Role granted!`);
    }
}

async function renounceRole(contractId, roleHash, accountAddress) {
    const description = `Renouncing role ${contractId}:${roleHash} from ${accountAddress}`;

    if (!deployment.config[description]) {
        console.log(`${description} ...`);
        const renounceRoleTx = await new ContractExecuteTransaction()
            .setContractId(contractId)
            .setFunction('renounceRole',
                new ContractFunctionParameters()
                    .addBytes32(ethers.utils.arrayify(roleHash))
                    .addAddress(accountAddress)
            )
            .setGas(400_000)
            .execute(client);
        const renounceRoleRx = await renounceRoleTx.getReceipt(client);
        deployment.config[description] = true;
        writePartialDeployment();
        console.log(`Role renounced!`);
    }
}