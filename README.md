# Pangolin for Hedera

## Scope

### [WrappedHedera](./contracts/WHBAR.sol)

The only changes made to existing widely-utilized wrapped AVAX contract was to change the decimals to 8, and token name to HBAR. It is an ERC20, not Hedera token. We decided to keep it as ERC20 to not have to modify our existing contracts.

### Core Pangolin Contracts

Contract versions were bumped to `0.6.12`. This required explicitly marking functions virtual or override. See commit e2138f5215f50769ccc447587d59ff78c9637eff for all changes.

[PangolinFactory](./contracts/pangolin-core/PangolinFactory.sol) was modified mildly to reduce storage. See commit a953141976e90a5c30685375293db7384e400d6c for details.

HederaTokenService was integrated to [PangolinPair](./contracts/pangolin-core/PangolinPair.sol). It will try to associate both reserve tokens, and if association fails, it will assume the token to be ERC20. This simple modification allows a pair to consist of two ERC20 tokens, two Hedera tokens, or one Hedera token and an ERC20 token. See commit 18d552a39e916c52c0606bf894f9cf88d114817a for details.

### [TreasuryVester](./contracts/TreasuryVester.sol)

This is a new contract specifically for Hedera. It creates, mints, and distributes a Hedera native PNG token. It mints an initial supply to be later transferred to an airdrop contract. The remaining tokens are vested based on a hard-coded schedule. The owner first defines recipients and their allocations to receive from the vesting.

### Out of Scope

Pangolin periphery contracts and Pangolin library contract are not in scope. They have no or minimal change. HTS contracts are also not in scope, as they only had changes to some of the function names to prevent collision.

## Deployment Flow

The contracts will be deployed to mainnet in the following order.

### Wrapped Hedera

1. Run `npx hardhat run scripts/deploy-WrappedHedera.js`,
2. Record the new contract ID, and add it to `WRAPPED_HEDERA` in `.env`.

### Multisig

1. Ensure `MY_PRIVATE_KEY`, `MY_ACCOUNT_ID` (Hedera address), and `ACCOUNT_IDS_FOR_MULTISIG` (comma-separated Hedera addresses) are defined in `.env`,
2. Run `npx hardhat run scripts/create-Multisig.js`,
3. Record the new contract ID,
4. Set `MULTISIG_ACCOUNT_ID` in `.env` to the new contract ID.

This is a native Hedera account. No need for smart contracts.

### Pangolin Factory

1. Ensure `MY_PRIVATE_KEY`, `MY_ACCOUNT_ID` (Hedera address), and `MULTISIG_ACCOUNT_ID` are defined in `.env`,
2. Run `npx hardhat run scripts/deploy-PangolinFactory.js`,
3. Record the deployed contract ID, and git commit hash.
4. Set the `feeTo` address of `PangolinFactory` to the appropriate address (e.g. FeeCollector) using the multisig.

### Pangolin Router

1. Ensure appropriate environment variables are set.
2. Run `npx hardhat run scripts/getPairHash.js`, and ensure the outputted hash is the same as in line 26 of `contracts/pangolin-periphery/libraries/PangolinLibrary.sol`. If it is not same, change it accordingly. Note that you should exclude `0x` prefix.
3. Run `npx hardhat run scripts/deploy-PangolinRouter.js`

### Treasury Vester and Pangolin Token

1. Ensure `MULTISIG_ACCOUNT_ID` is defined in `.env`,
2. Run `npx hardhat run scripts/deploy-TreasuryVester.js`,
3. Set recipients (planned: 1800 multisig/team, 2000 community treasury, 6200 PangoChef/farms) using multisig,
4. Whenever ready unpause the contract using multisig.

### Airdrop (TBD)

1. After airdrop contract is ready and deployed, use `transferInitialSupply` function of `TreasuryVester` to move initial supply to the airdrop contract.

Note that our existing airdrop contract will be re-used. During deployment through hedera-sdk, we will set `setMaxAutomaticTokenAssociations` to 1, and transfer a single PNG to trigger the association. Such that we will not need to make changes to our existing contracts.

### Other Contracts (TBD)

The rest of the contracts will require no or minimal modification. So they are excluded from this repo. `FeeCollector` and `CommunityTreasury` will require a restricted associate token function to be able to receive arbitrary Hedera tokens. `PangolinStakingPositions` (PNG staking contract, funded by FeeCollector) and `PangoChef` (farm rewards distributor, funded by TreasuryVester) will require no change, other than associating PNG during deployment. However, inbetween PangoChef and TreasuryVester, and inbetween PangolinStakingPositions and FeeCollector, there is a need for compatibility contracts, that take the funds from FeeCollector or TreasuryVester, with only purpose to relay them to PangolinStakingPositions and PangoChef, respectively.
