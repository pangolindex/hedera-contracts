const {ethers} = require('hardhat');
const fs = require('node:fs');
const path = require('node:path');
const ROLES = require('./static/roles');
const {
    Client,
    AccountId,
    ContractCreateFlow,
    Hbar,
    HbarUnit,
    ContractFunctionParameters,
    ContractCallQuery,
    AccountBalanceQuery,
    ContractExecuteTransaction,
} = require('@hashgraph/sdk');
require('dotenv').config({path: '../.env'});

// Shared global variables
let client;

async function main() {
    // Required environment variables
    const MY_ACCOUNT_ID = process.env.MY_ACCOUNT_ID;
    const MY_PRIVATE_KEY = process.env.MY_PRIVATE_KEY;
    const MULTISIG_ACCOUNT_ID = process.env.MULTISIG_ACCOUNT_ID;

    if (MY_ACCOUNT_ID == null || MY_PRIVATE_KEY == null || MULTISIG_ACCOUNT_ID == null) {
        throw new Error('Environment variables MY_ACCOUNT_ID, MY_PRIVATE_KEY, and MULTISIG_ACCOUNT_ID must be present');
    }

    // Optional environment variables
    const FACTORY_CONTRACT_ID = process.env.FACTORY_CONTRACT_ID;
    const WHBAR_CONTRACT_ID = process.env.WHBAR_CONTRACT_ID;
    const START_VESTING = process.env.START_VESTING;

    const TIMELOCK_DELAY = 86_400 * 2; // 2 days

    client = Client.forTestnet();
    client.setOperator(MY_ACCOUNT_ID, MY_PRIVATE_KEY);

    const deployment = {};
    const deployerAddress = `0x${AccountId.fromString(MY_ACCOUNT_ID).toSolidityAddress()}`;
    console.log(`Deployer: ${deployerAddress}`);

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
    const governor = await ethers.getContractFactory('Governor');
    const governorAssistant = await ethers.getContractFactory('GovernorAssistant');
    const timelock = await ethers.getContractFactory('Timelock');

    const balanceBefore = await new AccountBalanceQuery()
        .setAccountId(MY_ACCOUNT_ID)
        .execute(client);

    console.log('============================== DEPLOYMENT ==============================');

    // Multisig
    const multisigAddress = `0x${AccountId.fromString(MULTISIG_ACCOUNT_ID).toSolidityAddress()}`;
    console.log(`Multisig: ${multisigAddress}`);
    deployment['Multisig'] = multisigAddress;

    // Timelock
    const createTimelockTx = await new ContractCreateFlow()
        .setBytecode(timelock.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(deployerAddress) // admin
                .addUint256(TIMELOCK_DELAY) // delay
        )
        .setGas(100_000)
        .execute(client);
    const createTimelockRx = await createTimelockTx.getReceipt(client);
    const timelockId = createTimelockRx.contractId;
    const timelockAddress = `0x${AccountId.fromString(timelockId).toSolidityAddress()}`;
    console.log(`Timelock: ${timelockAddress}`);
    deployment['Timelock'] = timelockAddress;

    // WHBAR
    let wrappedNativeTokenContractId;
    let wrappedNativeTokenContractAddress;
    if (!WHBAR_CONTRACT_ID) {
        const createWrappedNativeTokenTx = await new ContractCreateFlow()
            .setBytecode(wrappedNativeTokenContract.bytecode)
            .setGas(400_000) // 349,451
            .setInitialBalance(new Hbar(40))
            .execute(client);
        const createWrappedNativeTokenRx = await createWrappedNativeTokenTx.getReceipt(client);
        wrappedNativeTokenContractId = createWrappedNativeTokenRx.contractId;
        wrappedNativeTokenContractAddress = `0x${AccountId.fromString(wrappedNativeTokenContractId).toSolidityAddress()}`;
    } else {
        wrappedNativeTokenContractId = WHBAR_CONTRACT_ID;
        wrappedNativeTokenContractAddress = `0x${AccountId.fromString(WHBAR_CONTRACT_ID).toSolidityAddress()}`;
    }
    console.log(`WHBAR (Contract): ${wrappedNativeTokenContractAddress}`);
    deployment['WHBAR (Contract)'] = wrappedNativeTokenContractAddress;

    // WHBAR HTS Address
    const whbarQueryTx = await new ContractCallQuery()
        .setContractId(wrappedNativeTokenContractId)
        .setGas(24_000) // 21,204
        .setFunction('TOKEN_ID')
        .execute(client);
    const wrappedNativeTokenHTSAddress = `0x${whbarQueryTx.getAddress(0)}`;
    console.log(`WHBAR (HTS): ${wrappedNativeTokenHTSAddress}`);
    deployment['WHBAR (HTS)'] = wrappedNativeTokenHTSAddress;

    // TreasuryVester
    const createTreasuryVesterTx = await new ContractCreateFlow()
        .setBytecode(treasuryVesterContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(deployerAddress) // admin (deployer for now and will be set to Multisig later)
        )
        .setGas(700_000) // 657,136
        .setInitialBalance(new Hbar(40))
        .execute(client);
    const createTreasuryVesterRx = await createTreasuryVesterTx.getReceipt(client);
    const treasuryVesterId = createTreasuryVesterRx.contractId;
    const treasuryVesterAddress = `0x${AccountId.fromString(treasuryVesterId).toSolidityAddress()}`;
    console.log(`TreasuryVester: ${treasuryVesterAddress}`);
    deployment['TreasuryVester'] = treasuryVesterAddress;

    // PNG HTS Information
    const pngQueryTx = await new ContractCallQuery()
        .setContractId(treasuryVesterId)
        .setGas(24_000) // 21,284
        .setFunction('PNG')
        .execute(client);
    const pngHTSAddress = `0x${pngQueryTx.getAddress(0)}`;
    console.log(`PNG (HTS): ${pngHTSAddress}`);
    deployment['PNG (HTS)'] = pngHTSAddress;

    // CommunityTreasury
    const createCommunityTreasuryTx = await new ContractCreateFlow()
        .setBytecode(communityTreasury.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pngHTSAddress)
        )
        .setGas(900_000) // 788,308
        .execute(client);
    const createCommunityTreasuryRx = await createCommunityTreasuryTx.getReceipt(client);
    const communityTreasuryId = createCommunityTreasuryRx.contractId;
    const communityTreasuryAddress = `0x${AccountId.fromString(communityTreasuryId).toSolidityAddress()}`;
    console.log(`CommunityTreasury: ${communityTreasuryAddress}`);
    deployment['CommunityTreasury'] = communityTreasuryAddress;

    // PangolinFactory
    let pangolinFactoryId;
    let pangolinFactoryAddress;
    if (!FACTORY_CONTRACT_ID) {
        const createPangolinFactoryTx = await new ContractCreateFlow()
            .setBytecode(pangolinFactoryContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(timelockAddress) // feeToSetter
            )
            .setGas(80_000) // 78,473
            .execute(client);
        const createPangolinFactoryRx = await createPangolinFactoryTx.getReceipt(client);
        pangolinFactoryId = createPangolinFactoryRx.contractId;
        pangolinFactoryAddress = `0x${AccountId.fromString(pangolinFactoryId).toSolidityAddress()}`;
    } else {
        pangolinFactoryId = FACTORY_CONTRACT_ID;
        pangolinFactoryAddress = `0x${AccountId.fromString(pangolinFactoryId).toSolidityAddress()}`;
    }
    console.log(`PangolinFactory: ${pangolinFactoryAddress}`);
    deployment['PangolinFactory'] = pangolinFactoryAddress;

    // PangolinRouter
    const createPangolinRouterTx = await new ContractCreateFlow()
        .setBytecode(pangolinRouterContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pangolinFactoryAddress) // factory
                .addAddress(wrappedNativeTokenContractAddress) // whbar
        )
        .setGas(900_000) // 765,518
        .execute(client);
    const createPangolinRouterRx = await createPangolinRouterTx.getReceipt(client);
    const pangolinRouterId = createPangolinRouterRx.contractId;
    const pangolinRouterAddress = `0x${AccountId.fromString(pangolinRouterId).toSolidityAddress()}`;
    console.log(`PangolinRouter: ${pangolinRouterAddress}`);
    deployment['PangolinRouter'] = pangolinRouterAddress;

    // Create PNG/WHBAR as first pair (required for PangolinFactory creation)
    const createFirstPairTx = await new ContractExecuteTransaction()
        .setContractId(pangolinFactoryId)
        .setFunction('createPair',
            new ContractFunctionParameters()
                .addAddress(pngHTSAddress)
                .addAddress(wrappedNativeTokenHTSAddress)
        )
        .setGas(1_900_000) // 1,893,647
        .setPayableAmount(new Hbar(40))
        .execute(client);
    const createFirstPairRx = await createFirstPairTx.getRecord(client);
    const firstPairAddress = `0x${createFirstPairRx.contractFunctionResult.getAddress(0)}`;
    console.log(`Pair PNG/WHBAR (Contract): ${firstPairAddress}`);
    deployment['Pair PNG/WHBAR (Contract)'] = firstPairAddress;

    // PangoChef
    const createPangoChefTx = await new ContractCreateFlow()
        .setBytecode(pangoChefContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pngHTSAddress) // newRewardsToken
                .addAddress(deployerAddress) // newAdmin (deployer for now and will be set to Multisig later)
                .addAddress(pangolinFactoryAddress) // newFactory
                .addAddress(wrappedNativeTokenHTSAddress) // newWrappedNativeToken
        )
        .setGas(3_000_000) // 2,768,485
        .execute(client);
    const createPangoChefRx = await createPangoChefTx.getReceipt(client);
    const pangoChefId = createPangoChefRx.contractId;
    const pangoChefAddress = `0x${AccountId.fromString(pangoChefId).toSolidityAddress()}`;
    console.log(`PangoChef: ${pangoChefAddress}`);
    deployment['PangoChef'] = pangoChefAddress;

    // RewardFundingForwarder (PangoChef)
    const createPangoChefRewardFundingForwarderTx = await new ContractCreateFlow()
        .setBytecode(rewardFundingForwarderContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pangoChefAddress) // pangoChef
        )
        .setGas(900_000)
        .execute(client);
    const createPangoChefRewardFundingForwarderRx = await createPangoChefRewardFundingForwarderTx.getReceipt(client);
    const pangoChefRewardFundingForwarderId = createPangoChefRewardFundingForwarderRx.contractId;
    const pangoChefRewardFundingForwarderAddress = `0x${AccountId.fromString(pangoChefRewardFundingForwarderId).toSolidityAddress()}`;
    console.log(`RewardFundingForwarder (PangoChef): ${pangoChefRewardFundingForwarderAddress}`);
    deployment['RewardFundingForwarder (PangoChef)'] = pangoChefRewardFundingForwarderAddress;

    // PangolinStakingPositions
    const createPangolinStakingPositionsTx = await new ContractCreateFlow()
        .setBytecode(pangolinStakingPositionsContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pngHTSAddress) // newRewardsToken
                .addAddress(deployerAddress) // newAdmin (deployer for now and will be set to Multisig later)
        )
        .setGas(1_400_000) // 1,390,489
        .setInitialBalance(new Hbar(40))
        .execute(client);
    const createPangolinStakingPositionsRx = await createPangolinStakingPositionsTx.getReceipt(client);
    const pangolinStakingPositionsId = createPangolinStakingPositionsRx.contractId;
    const pangolinStakingPositionsAddress = `0x${AccountId.fromString(pangolinStakingPositionsId).toSolidityAddress()}`;
    console.log(`PangolinStakingPositions: ${pangolinStakingPositionsAddress}`);
    deployment['PangolinStakingPositions'] = pangolinStakingPositionsAddress;

    // Pangolin Staking Positions NFT HTS Information
    const positionsTokenQueryTx = await new ContractCallQuery()
        .setContractId(pangolinStakingPositionsId)
        .setGas(24_000) // 21,284
        .setFunction('positionsToken')
        .execute(client);
    const pangolinStakingPositionsHTSAddress = `0x${positionsTokenQueryTx.getAddress(0)}`;
    console.log(`SSS NFT (HTS): ${pangolinStakingPositionsHTSAddress}`);
    deployment['SSS NFT (HTS)'] = pangolinStakingPositionsHTSAddress;

    // RewardFundingForwarder (PangolinStakingPositions)
    const createPangolinStakingPositionsRewardFundingForwarderTx = await new ContractCreateFlow()
        .setBytecode(rewardFundingForwarderContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pangolinStakingPositionsAddress) // pangolinStakingPositions
        )
        .setGas(900_000)
        .execute(client);
    const createPangolinStakingPositionsRewardFundingForwarderRx = await createPangolinStakingPositionsRewardFundingForwarderTx.getReceipt(client);
    const pangolinStakingPositionsRewardFundingForwarderId = createPangolinStakingPositionsRewardFundingForwarderRx.contractId;
    const pangolinStakingPositionsRewardFundingForwarderAddress = `0x${AccountId.fromString(pangolinStakingPositionsRewardFundingForwarderId).toSolidityAddress()}`;
    console.log(`RewardFundingForwarder (PangolinStakingPositions): ${pangolinStakingPositionsRewardFundingForwarderAddress}`);
    deployment['RewardFundingForwarder (PangolinStakingPositions)'] = pangolinStakingPositionsRewardFundingForwarderAddress;

    // EmissionDiversionFromPangoChefToPangolinStakingPositions
    console.log(`Deploying EmissionDiversionFromPangoChefToPangolinStakingPositions ...`);
    const createEmissionDiversionFromPangoChefToPangolinStakingPositionsTx = await new ContractCreateFlow()
        .setBytecode(EmissionDiversionFromPangoChefToPangolinStakingPositions.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pangoChefAddress)
                .addAddress(pangolinStakingPositionsAddress)
        )
        .setGas(950_000) // 793,453
        .execute(client);
    const createEmissionDiversionFromPangoChefToPangolinStakingPositionsRx = await createEmissionDiversionFromPangoChefToPangolinStakingPositionsTx.getReceipt(client);
    const emissionDiversionFromPangoChefToPangolinStakingPositionsId = createEmissionDiversionFromPangoChefToPangolinStakingPositionsRx.contractId;
    const emissionDiversionFromPangoChefToPangolinStakingPositionsAddress = `0x${AccountId.fromString(emissionDiversionFromPangoChefToPangolinStakingPositionsId).toSolidityAddress()}`;
    console.log(`EmissionDiversionFromPangoChefToPangolinStakingPositions ${emissionDiversionFromPangoChefToPangolinStakingPositionsId} (${emissionDiversionFromPangoChefToPangolinStakingPositionsAddress})`);

    // GovernorAssistant
    const createGovernorAssistantTx = await new ContractCreateFlow()
        .setBytecode(governorAssistant.bytecode)
        .setGas(100_000)
        .execute(client);
    const createGovernorAssistantRx = await createGovernorAssistantTx.getReceipt(client);
    const governorAssistantId = createGovernorAssistantRx.contractId;
    const governorAssistantAddress = `0x${AccountId.fromString(governorAssistantId).toSolidityAddress()}`;
    console.log(`Governor Assistant: ${governorAssistantAddress}`);
    deployment['Governor Assistant'] = governorAssistantAddress;

    // Governor
    const createGovernorTx = await new ContractCreateFlow()
        .setBytecode(governor.bytecode)
        .setConstructorParameters(new ContractFunctionParameters()
            .addAddress(governorAssistantAddress) // assistant
            .addAddress(timelockAddress) // timelock
            .addAddress(pangolinStakingPositionsHTSAddress) // PangolinStakingPositions HTS NFT
            .addAddress(pangolinStakingPositionsAddress) // PangolinStakingPositions contract
        )
        .setGas(100_000)
        .execute(client);
    const createGovernorRx = await createGovernorTx.getReceipt(client);
    const governorId = createGovernorRx.contractId;
    const governorAddress = `0x${AccountId.fromString(governorId).toSolidityAddress()}`;
    console.log(`Governor: ${governorAddress}`);
    deployment['Governor'] = governorAddress;

    // TODO: Deploy Airdrop
    // TODO: Deploy FeeCollector

    console.log('============================== CONFIGURATION: TIMELOCK ==============================');

    // Begin process of setting Timelock admin to Governor
    const queuePendingAdmin_bytes = new ContractFunctionParameters().addAddress(governorAddress)._build();
    const queuePendingAdmin_eta = Math.ceil(Date.now() / 1000) + TIMELOCK_DELAY + 60;
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
        .setGas(1_000_000)
        .execute(client);
    const queuePendingAdminRx = await queuePendingAdminTx.getReceipt(client);
    console.log(`Queued Governor as pending Timelock admin`);
    // Wait for TIMELOCK_DELAY seconds ...
    // Call Timelock.executeTransaction(timelockAddress, 0, queuePendingAdmin_bytes, queuePendingAdmin_eta)
    // Call Governor.__acceptAdmin()

    console.log('============================== CONFIGURATION: COMMUNITY TREASURY ==============================');

    const transferOwnershipCommunityTreasuryTx = await new ContractExecuteTransaction()
        .setContractId(communityTreasuryId)
        .setFunction('transferOwnership',
            new ContractFunctionParameters()
                .addAddress(timelockAddress)
        )
        .setGas(35_000)
        .execute(client);
    const transferOwnershipCommunityTreasuryRx = await transferOwnershipCommunityTreasuryTx.getReceipt(client);
    console.log('Transferred ownership of CommunityTreasury to Timelock');

    console.log('============================== CONFIGURATION: TREASURY VESTER ==============================');

    const VESTER_ALLOCATIONS = [
        {
            // Community Treasury
            address: communityTreasuryAddress,
            allocation: 2105, // 20%
        },
        {
            // Team
            address: multisigAddress,
            allocation: 1842, // 10% team + 5% vc investor + 2.5% advisory
        },
        {
            // Chef
            address: pangoChefRewardFundingForwarderAddress,
            allocation: 6053, // 57.5% LPs & PNG Staking
        }
    ];
    const vesterAccounts = VESTER_ALLOCATIONS.map(({address}) => address);
    const vesterAllocations = VESTER_ALLOCATIONS.map(({allocation}) => allocation);

    const setRecipientsTx = await new ContractExecuteTransaction()
        .setContractId(treasuryVesterId)
        .setFunction('setRecipients',
            new ContractFunctionParameters()
                .addAddressArray(vesterAccounts) // accounts
                .addInt64Array(vesterAllocations) // allocations
        )
        .setGas(130_000) // 120,821
        .execute(client);
    const setRecipientsRx = await setRecipientsTx.getReceipt(client);
    console.log(`Treasury vester recipients set`);

    if (START_VESTING?.toLowerCase() === 'true') {
        const unpauseTreasuryVesterTx = await new ContractExecuteTransaction()
            .setContractId(treasuryVesterId)
            .setFunction('unpause')
            .setGas(32_000) // 27,120
            .execute(client);
        const unpauseTreasuryVesterRx = await unpauseTreasuryVesterTx.getReceipt(client);
        console.log(`Vesting un-paused`);
    }

    await grantRole(treasuryVesterId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(treasuryVesterId, ROLES.DEFAULT_ADMIN_ROLE, deployerAddress);

    console.log('============================== CONFIGURATION: PANGOCHEF ==============================');

    const approvePangoChefRewardFundingForwarderTx = await new ContractExecuteTransaction()
        .setContractId(pangoChefRewardFundingForwarderId)
        .setFunction('approve')
        .setGas(900_000)
        .execute(client);
    const approvePangoChefRewardFundingForwarderRx = await approvePangoChefRewardFundingForwarderTx.getReceipt(client);
    console.log(`Setup approval for RewardFundingForwarder (PangoChef)`);

    await grantRole(pangoChefId, ROLES.FUNDER_ROLE, pangoChefRewardFundingForwarderAddress);
    await grantRole(pangoChefId, ROLES.FUNDER_ROLE, multisigAddress);
    await grantRole(pangoChefId, ROLES.POOL_MANAGER_ROLE, multisigAddress);
    await grantRole(pangoChefId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(pangoChefId, ROLES.FUNDER_ROLE, deployerAddress);
    await renounceRole(pangoChefId, ROLES.POOL_MANAGER_ROLE, deployerAddress);
    await renounceRole(pangoChefId, ROLES.DEFAULT_ADMIN_ROLE, deployerAddress);

    console.log('============================== CONFIGURATION: STAKING POSITIONS ==============================');

    const approvePangolinStakingPositionsRewardFundingForwarderTx = await new ContractExecuteTransaction()
        .setContractId(pangolinStakingPositionsRewardFundingForwarderId)
        .setFunction('approve')
        .setGas(900_000)
        .execute(client);
    const approvePangolinStakingPositionsRewardFundingForwarderRx = await approvePangolinStakingPositionsRewardFundingForwarderTx.getReceipt(client);
    console.log(`Setup approval for RewardFundingForwarder (PangolinStakingPositions)`);

    const approveEmissionDiversionFromPangoChefToPangolinStakingPositionsTx = await new ContractExecuteTransaction()
        .setContractId(emissionDiversionFromPangoChefToPangolinStakingPositionsId)
        .setFunction('approve')
        .setGas(900_000) // 732,126
        .execute(client);
    const approveEmissionDiversionFromPangoChefToPangolinStakingPositionsRx = await approveEmissionDiversionFromPangoChefToPangolinStakingPositionsTx.getReceipt(client);
    console.log(`Setup approval for EmissionDiversionFromPangoChefToPangolinStakingPositions`);

    // await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, feeCollectorAddress); // TODO: implement FeeCollector
    await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, pangolinStakingPositionsRewardFundingForwarderAddress);
    await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, multisigAddress);
    await grantRole(pangolinStakingPositionsId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, deployerAddress);
    await renounceRole(pangolinStakingPositionsId, ROLES.DEFAULT_ADMIN_ROLE, deployerAddress);

    const outputDirectory = path.join(__dirname, '..', 'deployments');
    const outputFile = path.join(outputDirectory, `testnet@${Date.now()}.json`);
    if (!fs.existsSync(outputDirectory)) {
        fs.mkdirSync(outputDirectory, {recursive: true});
    }
    fs.writeFileSync(outputFile, JSON.stringify(deployment), {encoding: 'utf-8'});

    const balanceAfter = await new AccountBalanceQuery()
        .setAccountId(MY_ACCOUNT_ID)
        .execute(client);

    const balanceDelta = balanceBefore.hbars.toBigNumber().minus(balanceAfter.hbars.toBigNumber());
    console.log(`HBAR cost: ${Hbar.from(balanceDelta, HbarUnit.Hbar).toString()}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

async function grantRole(contractId, roleHash, accountAddress) {
    const grantRoleTx = await new ContractExecuteTransaction()
        .setContractId(contractId)
        .setFunction('grantRole',
            new ContractFunctionParameters()
                .addBytes32(ethers.utils.arrayify(roleHash))
                .addAddress(accountAddress)
        )
        .setGas(200_000) // wtf
        .execute(client);
    const grantRoleRx = await grantRoleTx.getReceipt(client);
    console.log(`Role granted`);
}

async function renounceRole(contractId, roleHash, accountAddress) {
    const renounceRoleTx = await new ContractExecuteTransaction()
        .setContractId(contractId)
        .setFunction('renounceRole',
            new ContractFunctionParameters()
                .addBytes32(ethers.utils.arrayify(roleHash))
                .addAddress(accountAddress)
        )
        .setGas(200_000) // wtf
        .execute(client);
    const renounceRoleRx = await renounceRoleTx.getReceipt(client);
    console.log(`Role renounced`);
}