// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.4.9 <0.9.0;
pragma experimental ABIEncoderV2;

interface IHTS_NftVotingVault {

    /// Expiry properties of a Hedera token - second, autoRenewAccount, autoRenewPeriod
    struct Expiry {
        // The epoch second at which the token should expire; if an auto-renew account and period are
        // specified, this is coerced to the current epoch second plus the autoRenewPeriod
        uint32 second;

        // ID of an account which will be automatically charged to renew the token's expiration, at
        // autoRenewPeriod interval, expressed as a solidity address
        address autoRenewAccount;

        // The interval at which the auto-renew account will be charged to extend the token's expiry
        uint32 autoRenewPeriod;
    }

    /// A Key can be a public key from either the Ed25519 or ECDSA(secp256k1) signature schemes, where
    /// in the ECDSA(secp256k1) case we require the 33-byte compressed form of the public key. We call
    /// these public keys <b>primitive keys</b>.
    /// A Key can also be the ID of a smart contract instance, which is then authorized to perform any
    /// precompiled contract action that requires this key to sign.
    /// Note that when a Key is a smart contract ID, it <i>doesn't</i> mean the contract with that ID
    /// will actually create a cryptographic signature. It only means that when the contract calls a
    /// precompiled contract, the resulting "child transaction" will be authorized to perform any action
    /// controlled by the Key.
    /// Exactly one of the possible values should be populated in order for the Key to be valid.
    struct KeyValue {

        // if set to true, the key of the calling Hedera account will be inherited as the token key
        bool inheritAccountKey;

        // smart contract instance that is authorized as if it had signed with a key
        address contractId;

        // Ed25519 public key bytes
        bytes ed25519;

        // Compressed ECDSA(secp256k1) public key bytes
        bytes ECDSA_secp256k1;

        // A smart contract that, if the recipient of the active message frame, should be treated
        // as having signed. (Note this does not mean the <i>code being executed in the frame</i>
        // will belong to the given contract, since it could be running another contract's code via
        // <tt>delegatecall</tt>. So setting this key is a more permissive version of setting the
        // contractID key, which also requires the code in the active message frame belong to the
        // the contract with the given id.)
        address delegatableContractId;
    }

    /// A list of token key types the key should be applied to and the value of the key
    struct TokenKey {

        // bit field representing the key type. Keys of all types that have corresponding bits set to 1
        // will be created for the token.
        // 0th bit: adminKey
        // 1st bit: kycKey
        // 2nd bit: freezeKey
        // 3rd bit: wipeKey
        // 4th bit: supplyKey
        // 5th bit: feeScheduleKey
        // 6th bit: pauseKey
        // 7th bit: ignored
        uint keyType;

        // the value that will be set to the key type
        KeyValue key;
    }

    /// Basic properties of a Hedera Token - name, symbol, memo, tokenSupplyType, maxSupply,
    /// treasury, freezeDefault. These properties are related both to Fungible and NFT token types.
    struct HederaToken {
        // The publicly visible name of the token. The token name is specified as a Unicode string.
        // Its UTF-8 encoding cannot exceed 100 bytes, and cannot contain the 0 byte (NUL).
        string name;

        // The publicly visible token symbol. The token symbol is specified as a Unicode string.
        // Its UTF-8 encoding cannot exceed 100 bytes, and cannot contain the 0 byte (NUL).
        string symbol;

        // The ID of the account which will act as a treasury for the token as a solidity address.
        // This account will receive the specified initial supply or the newly minted NFTs in
        // the case for NON_FUNGIBLE_UNIQUE Type
        address treasury;

        // The memo associated with the token (UTF-8 encoding max 100 bytes)
        string memo;

        // IWA compatibility. Specified the token supply type. Defaults to INFINITE
        bool tokenSupplyType;

        // IWA Compatibility. Depends on TokenSupplyType. For tokens of type FUNGIBLE_COMMON - the
        // maximum number of tokens that can be in circulation. For tokens of type NON_FUNGIBLE_UNIQUE -
        // the maximum number of NFTs (serial numbers) that can be minted. This field can never be changed!
        int64 maxSupply;

        // The default Freeze status (frozen or unfrozen) of Hedera accounts relative to this token. If
        // true, an account must be unfrozen before it can receive the token
        bool freezeDefault;

        // list of keys to set to the token
        TokenKey[] tokenKeys;

        // expiry properties of a Hedera token - second, autoRenewAccount, autoRenewPeriod
        Expiry expiry;
    }

    /// Additional post creation fungible and non fungible properties of a Hedera Token.
    struct TokenInfo {
        /// Basic properties of a Hedera Token
        HederaToken token;

        /// The number of tokens (fungible) or serials (non-fungible) of the token
        uint64 totalSupply;

        /// Specifies whether the token is deleted or not
        bool deleted;

        /// Specifies whether the token kyc was defaulted with KycNotApplicable (true) or Revoked (false)
        bool defaultKycStatus;

        /// Specifies whether the token is currently paused or not
        bool pauseStatus;

        /// The fixed fees collected when transferring the token
        FixedFee[] fixedFees;

        /// The fractional fees collected when transferring the token
        FractionalFee[] fractionalFees;

        /// The royalty fees collected when transferring the token
        RoyaltyFee[] royaltyFees;

        /// The ID of the network ledger
        string ledgerId;
    }

    /// Additional non fungible properties of a Hedera Token.
    struct NonFungibleTokenInfo {
        /// The shared hedera token info
        TokenInfo tokenInfo;

        /// The serial number of the nft
        int64 serialNumber;

        /// The account id specifying the owner of the non fungible token
        address ownerId;

        /// The epoch second at which the token was created.
        int64 creationTime;

        /// The unique metadata of the NFT
        bytes metadata;

        /// The account id specifying an account that has been granted spending permissions on this nft
        address spenderId;
    }

    /// A fixed number of units (hbar or token) to assess as a fee during a transfer of
    /// units of the token to which this fixed fee is attached. The denomination of
    /// the fee depends on the values of tokenId, useHbarsForPayment and
    /// useCurrentTokenForPayment. Exactly one of the values should be set.
    struct FixedFee {

        uint32 amount;

        // Specifies ID of token that should be used for fixed fee denomination
        address tokenId;

        // Specifies this fixed fee should be denominated in Hbar
        bool useHbarsForPayment;

        // Specifies this fixed fee should be denominated in the Token currently being created
        bool useCurrentTokenForPayment;

        // The ID of the account to receive the custom fee, expressed as a solidity address
        address feeCollector;
    }

    /// A fraction of the transferred units of a token to assess as a fee. The amount assessed will never
    /// be less than the given minimumAmount, and never greater than the given maximumAmount.  The
    /// denomination is always units of the token to which this fractional fee is attached.
    struct FractionalFee {
        // A rational number's numerator, used to set the amount of a value transfer to collect as a custom fee
        uint32 numerator;

        // A rational number's denominator, used to set the amount of a value transfer to collect as a custom fee
        uint32 denominator;

        // The minimum amount to assess
        uint32 minimumAmount;

        // The maximum amount to assess (zero implies no maximum)
        uint32 maximumAmount;
        bool netOfTransfers;

        // The ID of the account to receive the custom fee, expressed as a solidity address
        address feeCollector;
    }

    /// A fee to assess during a transfer that changes ownership of an NFT. Defines the fraction of
    /// the fungible value exchanged for an NFT that the ledger should collect as a royalty. ("Fungible
    /// value" includes both ℏ and units of fungible HTS tokens.) When the NFT sender does not receive
    /// any fungible value, the ledger will assess the fallback fee, if present, to the new NFT owner.
    /// Royalty fees can only be added to tokens of type type NON_FUNGIBLE_UNIQUE.
    struct RoyaltyFee {
        // A fraction's numerator of fungible value exchanged for an NFT to collect as royalty
        uint32 numerator;

        // A fraction's denominator of fungible value exchanged for an NFT to collect as royalty
        uint32 denominator;

        // If present, the fee to assess to the NFT receiver when no fungible value
        // is exchanged with the sender. Consists of:
        // amount: the amount to charge for the fee
        // tokenId: Specifies ID of token that should be used for fixed fee denomination
        // useHbarsForPayment: Specifies this fee should be denominated in Hbar
        uint32 amount;
        address tokenId;
        bool useHbarsForPayment;

        // The ID of the account to receive the custom fee, expressed as a solidity address
        address feeCollector;
    }

    /**********************
     * Direct HTS Calls   *
     **********************/

    /// Mints an amount of the token to the defined treasury account
    /// @param token The token for which to mint tokens. If token does not exist, transaction results in
    ///              INVALID_TOKEN_ID
    /// @param amount Applicable to tokens of type FUNGIBLE_COMMON. The amount to mint to the Treasury Account.
    ///               Amount must be a positive non-zero number represented in the lowest denomination of the
    ///               token. The new supply must be lower than 2^63.
    /// @param metadata Applicable to tokens of type NON_FUNGIBLE_UNIQUE. A list of metadata that are being created.
    ///                 Maximum allowed size of each metadata is 100 bytes
    /// @return newTotalSupply The new supply of tokens. For NFTs it is the total count of NFTs
    /// @return serialNumbers If the token is an NFT the newly generate serial numbers, othersise empty.
    function mintToken(
        address token,
        uint64 amount,
        bytes[] memory metadata
    )
    external
    returns (
        uint64 newTotalSupply,
        int64[] memory serialNumbers
    );

    /// Burns an amount of the token from the defined treasury account
    /// @param token The token for which to burn tokens. If token does not exist, transaction results in
    ///              INVALID_TOKEN_ID
    /// @param amount  Applicable to tokens of type FUNGIBLE_COMMON. The amount to burn from the Treasury Account.
    ///                Amount must be a positive non-zero number, not bigger than the token balance of the treasury
    ///                account (0; balance], represented in the lowest denomination.
    /// @param serialNumbers Applicable to tokens of type NON_FUNGIBLE_UNIQUE. The list of serial numbers to be burned.
    /// @return newTotalSupply The new supply of tokens. For NFTs it is the total count of NFTs
    function burnToken(
        address token,
        uint64 amount,
        int64[] memory serialNumbers
    ) external returns (uint64 newTotalSupply);

    /// Single-token variant of associateTokens. Will be mapped to a single entry array call of associateTokens
    /// @param account The account to be associated with the provided token
    /// @param token The token to be associated with the provided account
    function associateToken(address account, address token)
    external;

    /// Creates an Non Fungible Unique Token with the specified properties
    /// @param token the basic properties of the token being created
    /// @return tokenAddress the created token's address
    function createNonFungibleToken(HederaToken memory token)
    external
    payable
    returns (address tokenAddress);

    /// Query non fungible token info
    /// @param token The token address to check
    /// @param serialNumber The NFT serialNumber to check
    /// @return nonFungibleTokenInfo NonFungibleTokenInfo info for `token` `serialNumber`
    function getNonFungibleTokenInfo(address token, int64 serialNumber)
    external
    returns (NonFungibleTokenInfo memory nonFungibleTokenInfo);

    /**********************
     * ABIV1 calls        *
     **********************/

    /// Transfers tokens where the calling account/contract is implicitly the first entry in the token transfer list,
    /// where the amount is the value needed to zero balance the transfers. Regular signing rules apply for sending
    /// (positive amount) or receiving (negative amount)
    /// @param token The token to transfer to/from
    /// @param sender The sender for the transaction
    /// @param recipient The receiver of the transaction
    /// @param serialNumber The serial number of the NFT to transfer.
    function transferNFT(
        address token,
        address sender,
        address recipient,
        int64 serialNumber
    ) external;
}
