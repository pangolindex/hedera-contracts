const {ethers} = require('hardhat');
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

    const client = Client.forTestnet();
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
        .setPayableAmount(new Hbar(25))
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

    // TODO: RewardFundingForwarder
    // const createRewardFundingForwarderTx = await new ContractCreateFlow()
    //     .setBytecode(rewardFundingForwarderContract.bytecode)
    //     .setConstructorParameters(
    //         new ContractFunctionParameters()
    //             .addAddress(pangoChefAddress) // pangoChef
    //     )
    //     .setGas(1_000_000)
    //     .execute(client);
    // const createRewardFundingForwarderRx = await createRewardFundingForwarderTx.getReceipt(client);
    // const rewardFundingForwarderId = createRewardFundingForwarderRx.contractId;
    // const rewardFundingForwarderAddress = `0x${AccountId.fromString(rewardFundingForwarderId).toSolidityAddress()}`;
    // console.log(`RewardFundingForwarder: ${rewardFundingForwarderAddress}`);

    // TODO: PangolinStakingPositions
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

    // TODO: Deploy Airdrop
    // TODO: Deploy FeeCollector
    
    console.log('=============== CONFIGURATION ===============');

    // let vesterAllocations = [];
    // for (let i = 0; i < VESTER_ALLOCATIONS.length; i++) {
    //     let recipientAddress;
    //     let isMiniChef;
    //     if (VESTER_ALLOCATIONS[i].recipient === 'treasury') {
    //         recipientAddress = treasury.address;
    //         isMiniChef = false;
    //     } else if (VESTER_ALLOCATIONS[i].recipient === 'multisig') {
    //         recipientAddress = multisigAddress;
    //         isMiniChef = false;
    //     } else if (VESTER_ALLOCATIONS[i].recipient === 'chef') {
    //         recipientAddress = chefFundForwarder.address;
    //         isMiniChef = true;
    //     }
    //
    //     vesterAllocations.push([
    //         recipientAddress,
    //         VESTER_ALLOCATIONS[i].allocation,
    //         isMiniChef,
    //     ]);
    // }
    //
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
    //
    // await factory.setFeeToSetter(multisigAddress);
    // console.log('Transferred PangolinFactory ownership to Multisig.');
    //
    // /*******************
    //  * PANGOCHEF ROLES *
    //  *******************/
    //
    // await chef.grantRole(FUNDER_ROLE, vester.address);
    // await chef.grantRole(FUNDER_ROLE, chefFundForwarder.address);
    // await chef.grantRole(FUNDER_ROLE, multisigAddress);
    // await chef.grantRole(POOL_MANAGER_ROLE, multisigAddress);
    // await chef.grantRole(DEFAULT_ADMIN_ROLE, multisigAddress);
    // console.log('Added TreasuryVester as PangoChef funder.');
    //
    // await chef.setWeights(['0'], [WETH_PNG_FARM_ALLOCATION]);
    // console.log('Gave 30x weight to PNG-NATIVE_TOKEN');
    //
    // await chef.renounceRole(FUNDER_ROLE, myAccountAddress);
    // await chef.renounceRole(POOL_MANAGER_ROLE, myAccountAddress);
    // await chef.renounceRole(DEFAULT_ADMIN_ROLE, myAccountAddress);
    // console.log('Transferred PangoChef ownership to Multisig.');
    //
    // /************************* *
    //  * STAKING POSITIONS ROLES *
    //  ************************* */
    //
    // await staking.grantRole(FUNDER_ROLE, feeCollector.address);
    // await staking.grantRole(FUNDER_ROLE, stakingFundForwarder.address);
    // await staking.grantRole(FUNDER_ROLE, multisigAddress);
    // await staking.grantRole(DEFAULT_ADMIN_ROLE, multisigAddress);
    // console.log('Added FeeCollector as PangolinStakingPosition funder.');
    //
    // await staking.renounceRole(FUNDER_ROLE, myAccountAddress);
    // await staking.renounceRole(DEFAULT_ADMIN_ROLE, myAccountAddress);
    // console.log('Transferred PangolinStakingPositions ownership to Multisig.');

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
