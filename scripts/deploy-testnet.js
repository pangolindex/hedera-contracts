const {ethers} = require('hardhat');
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
    ContractExecuteTransaction
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

    client = Client.forTestnet();
    client.setOperator(MY_ACCOUNT_ID, MY_PRIVATE_KEY);

    const myAccountAddress = `0x${AccountId.fromString(MY_ACCOUNT_ID).toSolidityAddress()}`;

    console.log(`Deployer: ${myAccountAddress}`);

    const wrappedNativeTokenContract = await ethers.getContractFactory('WHBAR');
    const treasuryVesterContract = await ethers.getContractFactory('TreasuryVester');
    const pangolinFactoryContract = await ethers.getContractFactory('PangolinFactory');
    const pangolinPairContract = await ethers.getContractFactory('PangolinPair');
    const pangolinPairInitHash = ethers.utils.keccak256(pangolinPairContract.bytecode);
    const pangoChefContract = await ethers.getContractFactory('PangoChef');
    const rewardFundingForwarderContract = await ethers.getContractFactory('RewardFundingForwarder');
    const pangolinStakingPositionsContract = await ethers.getContractFactory('PangolinStakingPositions');

    const balanceBefore = await new AccountBalanceQuery()
        .setAccountId(MY_ACCOUNT_ID)
        .execute(client);


    console.log('============ DEPLOYMENT ============');

    // WHBAR
    let wrappedNativeTokenContractId;
    let wrappedNativeTokenContractAddress;
    if (!WHBAR_CONTRACT_ID) {
        const createWrappedNativeTokenTx = await new ContractCreateFlow()
            .setBytecode(wrappedNativeTokenContract.bytecode)
            .setGas(400_000)
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

    // WHBAR HTS Address
    const whbarQueryTx = await new ContractCallQuery()
        .setContractId(wrappedNativeTokenContractId)
        .setGas(40_000)
        .setFunction('TOKEN_ID')
        .execute(client);
    const wrappedNativeTokenHTSAddress = whbarQueryTx.getAddress(0);
    console.log(`WHBAR (HTS): ${wrappedNativeTokenHTSAddress}`);

    // TreasuryVester
    const createTreasuryVesterTx = await new ContractCreateFlow()
        .setBytecode(treasuryVesterContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(myAccountAddress) // admin
        )
        .setGas(800_000)
        .setInitialBalance(new Hbar(40))
        .execute(client);
    const createTreasuryVesterRx = await createTreasuryVesterTx.getReceipt(client);
    const treasuryVesterId = createTreasuryVesterRx.contractId;
    const treasuryVesterAddress = `0x${AccountId.fromString(treasuryVesterId).toSolidityAddress()}`;
    console.log(`TreasuryVester: ${treasuryVesterAddress}`);

    // PNG HTS Information
    const pngQueryTx = await new ContractCallQuery()
        .setContractId(treasuryVesterId)
        .setGas(45_000)
        .setFunction('PNG')
        .execute(client);
    const pngHTSAddress = pngQueryTx.getAddress(0);
    console.log(`PNG (HTS): ${pngHTSAddress}`);

    // Multisig
    const multisigAddress = `0x${AccountId.fromString(MULTISIG_ACCOUNT_ID).toSolidityAddress()}`;
    console.log(`Multisig: ${multisigAddress}`);

    // PangolinFactory
    let pangolinFactoryId;
    let pangolinFactoryAddress;
    if (!FACTORY_CONTRACT_ID) {
        const createPangolinFactoryTx = await new ContractCreateFlow()
            .setBytecode(pangolinFactoryContract.bytecode)
            .setConstructorParameters(
                new ContractFunctionParameters()
                    .addAddress(multisigAddress) // feeToSetter
            )
            .setGas(80_000)
            .execute(client);
        const createPangolinFactoryRx = await createPangolinFactoryTx.getReceipt(client);
        pangolinFactoryId = createPangolinFactoryRx.contractId;
        pangolinFactoryAddress = `0x${AccountId.fromString(pangolinFactoryId).toSolidityAddress()}`;
    } else {
        pangolinFactoryId = FACTORY_CONTRACT_ID;
        pangolinFactoryAddress = `0x${AccountId.fromString(pangolinFactoryId).toSolidityAddress()}`;
    }
    console.log(`PangolinFactory: ${pangolinFactoryAddress}`);

    // PangolinRouter
    const createPangolinRouterTx = await new ContractCreateFlow()
        .setBytecode(pangolinFactoryContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pangolinFactoryAddress) // factory
                .addAddress(wrappedNativeTokenContractAddress) // whbar
        )
        .setGas(550_000)
        .execute(client);
    const createPangolinRouterRx = await createPangolinRouterTx.getReceipt(client);
    const pangolinRouterId = createPangolinRouterRx.contractId;
    const pangolinRouterAddress = `0x${AccountId.fromString(pangolinRouterId).toSolidityAddress()}`;
    console.log(`PangolinRouter: ${pangolinRouterAddress}`);

    // Create PNG/WHBAR as first pair (required for PangolinFactory creation)
    const createFirstPairTx = await new ContractExecuteTransaction()
        .setContractId(pangolinFactoryId)
        .setFunction('createPair',
            new ContractFunctionParameters()
                .addAddress(pngHTSAddress)
                .addAddress(wrappedNativeTokenHTSAddress)
        )
        .setGas(2_000_000)
        .setPayableAmount(new Hbar(40))
        .execute(client);
    const createFirstPairRx = await createFirstPairTx.getReceipt(client);
    console.log(`PNG/WHBAR pair created`);

    // PangoChef
    const createPangoChefTx = await new ContractCreateFlow()
        .setBytecode(pangoChefContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pngHTSAddress) // newRewardsToken
                .addAddress(multisigAddress) // newAdmin
                .addAddress(pangolinFactoryAddress) // newFactory
                .addAddress(wrappedNativeTokenHTSAddress) // newWrappedNativeToken
        )
        .setGas(6_000_000)
        .execute(client);
    const createPangoChefRx = await createPangoChefTx.getReceipt(client);
    const pangoChefId = createPangoChefRx.contractId;
    const pangoChefAddress = `0x${AccountId.fromString(pangoChefId).toSolidityAddress()}`;
    console.log(`PangoChef: ${pangoChefAddress}`);

    // RewardFundingForwarder (PangoChef)
    // const createPangoChefRewardFundingForwarderTx = await new ContractCreateFlow()
    //     .setBytecode(rewardFundingForwarderContract.bytecode)
    //     .setConstructorParameters(
    //         new ContractFunctionParameters()
    //             .addAddress(pangoChefAddress) // pangoChef
    //     )
    //     .setGas(1_200_000)
    //     .execute(client);
    // const createPangoChefRewardFundingForwarderRx = await createPangoChefRewardFundingForwarderTx.getReceipt(client);
    // const pangoChefRewardFundingForwarderId = createPangoChefRewardFundingForwarderRx.contractId;
    // const pangoChefRewardFundingForwarderAddress = `0x${AccountId.fromString(pangoChefRewardFundingForwarderId).toSolidityAddress()}`;
    // console.log(`RewardFundingForwarder (PangoChef): ${pangoChefRewardFundingForwarderAddress}`);

    // PangolinStakingPositions
    const createPangolinStakingPositionsTx = await new ContractCreateFlow()
        .setBytecode(pangolinStakingPositionsContract.bytecode)
        .setConstructorParameters(
            new ContractFunctionParameters()
                .addAddress(pngHTSAddress) // newRewardsToken
                .addAddress(multisigAddress) // newAdmin
        )
        .setGas(1_400_000)
        .setInitialBalance(new Hbar(40))
        .execute(client);
    const createPangolinStakingPositionsRx = await createPangolinStakingPositionsTx.getReceipt(client);
    const pangolinStakingPositionsId = createPangolinStakingPositionsRx.contractId;
    const pangolinStakingPositionsAddress = `0x${AccountId.fromString(pangolinStakingPositionsId).toSolidityAddress()}`;
    console.log(`PangolinStakingPositions: ${pangolinStakingPositionsAddress}`);

    // RewardFundingForwarder (PangolinStakingPositions)
    // const createPangolinStakingPositionsRewardFundingForwarderTx = await new ContractCreateFlow()
    //     .setBytecode(rewardFundingForwarderContract.bytecode)
    //     .setConstructorParameters(
    //         new ContractFunctionParameters()
    //             .addAddress(pangolinStakingPositionsAddress) // pangolinStakingPositions
    //     )
    //     .setGas(1_000_000)
    //     .execute(client);
    // const createPangolinStakingPositionsRewardFundingForwarderRx = await createPangolinStakingPositionsRewardFundingForwarderTx.getReceipt(client);
    // const pangolinStakingPositionsRewardFundingForwarderId = createPangolinStakingPositionsRewardFundingForwarderRx.contractId;
    // const pangolinStakingPositionsRewardFundingForwarderAddress = `0x${AccountId.fromString(pangolinStakingPositionsRewardFundingForwarderId).toSolidityAddress()}`;
    // console.log(`RewardFundingForwarder (PangolinStakingPositions): ${pangolinStakingPositionsRewardFundingForwarderAddress}`);

    // TODO: Deploy Airdrop
    // TODO: Deploy FeeCollector
    
    console.log('=============== CONFIGURATION ===============');

    const VESTER_ALLOCATIONS = [
        {
            // Community Treasury
            address: multisigAddress, // TODO: implement treasury. vest to multisig for now
            allocation: 2105, // 20%
        },
        {
            // Team
            address: multisigAddress,
            allocation: 1842, // 10% team + 5% vc investor + 2.5% advisory
        },
        {
            // Chef
            address: myAccountAddress, // TODO: implement pangoChefRewardFundingForwarderAddress. vest to EOA for now
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
        .setGas(500_000)
        .execute(client);
    const setRecipientsRx = await setRecipientsTx.getReceipt(client);
    console.log(`Treasury vester recipients set`);


    // await airdrop.setMerkleRoot(AIRDROP_MERKLE_ROOT);
    // console.log('Set airdrop merkle root.');
    //
    // if (START_VESTING) {
    //     await airdrop.unpause();
    //     await confirmTransactionCount();
    //     console.log('Unpaused airdrop claiming.');
    // }
    //
    // await airdrop.transferOwnership(multisigAddress);
    // console.log('Transferred airdrop ownership to multisig.');
    //
    // await treasury.transferOwnership(timelock.address);
    // console.log('Transferred CommunityTreasury ownership to Timelock.');
    //
    // await png.grantRole(MINTER_ROLE, vester.address);
    // console.log('Gave PNG minting role to TreasuryVester.');
    //
    // await png.grantRole(DEFAULT_ADMIN_ROLE, multisigAddress);
    // await png.renounceRole(DEFAULT_ADMIN_ROLE, myAccountAddress);
    // console.log('Renounced PNG admin role to multisig.');
    //
    // await png.transfer(
    //     airdrop.address,
    //     ethers.utils.parseUnits(AIRDROP_AMOUNT.toString(), 18)
    // );
    // console.log(
    //     'Transferred',
    //     AIRDROP_AMOUNT.toString(),
    //     PNG_SYMBOL,
    //     'to Airdrop.'
    // );
    //
    // await png.transfer(
    //     multisigAddress,
    //     ethers.utils.parseUnits((INITIAL_MINT - AIRDROP_AMOUNT).toString(), 18)
    // );
    // console.log(
    //     'Transferred',
    //     (INITIAL_MINT - AIRDROP_AMOUNT).toString(),
    //     PNG_SYMBOL,
    //     'to Multisig.'
    // );
    //
    // if (START_VESTING) {
    //     await vester.startVesting();
    //     console.log('Token vesting began.');
    // }
    //
    // await vester.transferOwnership(timelock.address);
    // console.log('Transferred TreasuryVester ownership to Timelock.');
    //
    // // change swap fee recipient to fee collector
    // await factory.setFeeTo(feeCollector.address);
    // console.log('Set FeeCollector as the swap fee recipient.');

    const setFeeToSetterTx = await new ContractExecuteTransaction()
        .setContractId(pangolinFactoryId)
        .setFunction('setFeeToSetter',
            new ContractFunctionParameters()
                .addAddress(multisigAddress)
        )
        .setGas(50_000)
        .execute(client);
    const setFeeToSetterRx = await setFeeToSetterTx.getReceipt(client);
    console.log('Transferred PangolinFactory ownership to Multisig.');


    /*******************
     * PANGOCHEF ROLES *
     *******************/

    await grantRole(pangoChefId, ROLES.FUNDER_ROLE, myAccountAddress); // TODO: implement pangoChefRewardFundingForwarderAddress. fund via EOA for now
    await grantRole(pangoChefId, ROLES.FUNDER_ROLE, multisigAddress);

    await grantRole(pangoChefId, ROLES.POOL_MANAGER_ROLE, multisigAddress);
    await grantRole(pangoChefId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(pangoChefId, ROLES.FUNDER_ROLE, myAccountAddress);
    await renounceRole(pangoChefId, ROLES.POOL_MANAGER_ROLE, myAccountAddress);
    await renounceRole(pangoChefId, ROLES.DEFAULT_ADMIN_ROLE, myAccountAddress);

    /************************* *
     * STAKING POSITIONS ROLES *
     ************************* */

    // TODO: deploy FeeCollector
    // await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, feeCollectorAddress);
    await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, myAccountAddress); // TODO: implement pangoChefRewardFundingForwarderAddress. fund via EOA for now
    await grantRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, multisigAddress);
    await grantRole(pangolinStakingPositionsId, ROLES.DEFAULT_ADMIN_ROLE, multisigAddress);

    await renounceRole(pangolinStakingPositionsId, ROLES.FUNDER_ROLE, myAccountAddress);
    await renounceRole(pangolinStakingPositionsId, ROLES.DEFAULT_ADMIN_ROLE, myAccountAddress);


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
        .setGas(32_000)
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
        .setGas(32_000)
        .execute(client);
    const renounceRoleRx = await renounceRoleTx.getReceipt(client);
    console.log(`Role renounced`);
}