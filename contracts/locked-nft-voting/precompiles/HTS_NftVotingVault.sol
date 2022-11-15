// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.5.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "./IHTS_NftVotingVault.sol";

abstract contract HTS_NftVotingVault {
    address constant precompileAddress = address(0x167);
    // 90 days in seconds
    uint32 constant defaultAutoRenewPeriod = 7776000;

    int32 internal constant UNKNOWN = 21; // The responding node has submitted the transaction to the network. Its final status is still unknown.
    int32 internal constant SUCCESS = 22; // The transaction succeeded

    modifier nonEmptyExpiry(IHTS_NftVotingVault.HederaToken memory token)
    {
        if (token.expiry.second == 0 && token.expiry.autoRenewPeriod == 0) {
            token.expiry.autoRenewPeriod = defaultAutoRenewPeriod;
        }
        _;
    }

    /// Mints an amount of the token to the defined treasury account
    /// @param token The token for which to mint tokens. If token does not exist, transaction results in
    ///              INVALID_TOKEN_ID
    /// @param amount Applicable to tokens of type FUNGIBLE_COMMON. The amount to mint to the Treasury Account.
    ///               Amount must be a positive non-zero number represented in the lowest denomination of the
    ///               token. The new supply must be lower than 2^63.
    /// @param metadata Applicable to tokens of type NON_FUNGIBLE_UNIQUE. A list of metadata that are being created.
    ///                 Maximum allowed size of each metadata is 100 bytes
    /// @return newTotalSupply The new supply of tokens. For NFTs it is the total count of NFTs
    /// @return serialNumbers If the token is an NFT the newly generate serial numbers, otherwise empty.
    function mintToken(address token, uint64 amount, bytes[] memory metadata) internal
    returns (uint64 newTotalSupply, int64[] memory serialNumbers)
    {
        (bool success, bytes memory result) = precompileAddress.call(
            abi.encodeWithSelector(IHTS_NftVotingVault.mintToken.selector,
            token, amount, metadata));
        require(success, "mintToken failed");
        int32 responseCode;
        (responseCode, newTotalSupply, serialNumbers) = abi.decode(result, (int32, uint64, int64[]));
        require(responseCode == SUCCESS, "mintToken error");
    }

    /// Burns an amount of the token from the defined treasury account
    /// @param token The token for which to burn tokens. If token does not exist, transaction results in
    ///              INVALID_TOKEN_ID
    /// @param amount  Applicable to tokens of type FUNGIBLE_COMMON. The amount to burn from the Treasury Account.
    ///                Amount must be a positive non-zero number, not bigger than the token balance of the treasury
    ///                account (0; balance], represented in the lowest denomination.
    /// @param serialNumbers Applicable to tokens of type NON_FUNGIBLE_UNIQUE. The list of serial numbers to be burned.
    /// @return newTotalSupply The new supply of tokens. For NFTs it is the total count of NFTs
    function burnToken(address token, uint64 amount, int64[] memory serialNumbers) internal
    returns (uint64 newTotalSupply)
    {
        (bool success, bytes memory result) = precompileAddress.call(
            abi.encodeWithSelector(IHTS_NftVotingVault.burnToken.selector,
            token, amount, serialNumbers));
        require(success, "burnToken failed");
        int32 responseCode;
        (responseCode, newTotalSupply) = abi.decode(result, (int32, uint64));
        require(responseCode == SUCCESS, "burnToken error");
    }

    function associateToken(address account, address token) internal {
        (bool success, bytes memory result) = precompileAddress.call(
            abi.encodeWithSelector(IHTS_NftVotingVault.associateToken.selector,
            account, token));
        require(success, "associateToken failed");
        int32 responseCode = abi.decode(result, (int32));
        require(responseCode == SUCCESS, "associateToken error");
    }

    /// Creates an Non Fungible Unique Token with the specified properties
    /// @param token the basic properties of the token being created
    /// @return tokenAddress the created token's address
    function createNonFungibleToken(IHTS_NftVotingVault.HederaToken memory token) nonEmptyExpiry(token)
    internal returns (address tokenAddress) {
        (bool success, bytes memory result) = precompileAddress.call{value : msg.value}(
            abi.encodeWithSelector(IHTS_NftVotingVault.createNonFungibleToken.selector, token));
        require(success, "createNonFungibleToken failed");
        int32 responseCode;
        (responseCode, tokenAddress) = abi.decode(result, (int32, address));
        require(responseCode == SUCCESS, "createNonFungibleToken error");
    }

    /// Retrieves non-fungible specific token info for a given NFT
    /// @param token The ID of the token as a solidity address
    function getNonFungibleTokenInfo(address token, int64 serialNumber) internal returns (IHTS_NftVotingVault.NonFungibleTokenInfo memory tokenInfo) {
        (bool success, bytes memory result) = precompileAddress.call(
            abi.encodeWithSelector(IHTS_NftVotingVault.getNonFungibleTokenInfo.selector, token, serialNumber));
        require(success, "getNonFungibleTokenInfo failed");
        int32 responseCode;
        (responseCode, tokenInfo) = abi.decode(result, (int32, IHTS_NftVotingVault.NonFungibleTokenInfo));
        require(responseCode == SUCCESS, "getNonFungibleTokenInfo error");
    }

    /**********************
     * ABI v1 calls       *
     **********************/

    /// Transfers tokens where the calling account/contract is implicitly the first entry in the token transfer list,
    /// where the amount is the value needed to zero balance the transfers. Regular signing rules apply for sending
    /// (positive amount) or receiving (negative amount)
    /// @param token The token to transfer to/from
    /// @param sender The sender for the transaction
    /// @param receiver The receiver of the transaction
    /// @param serialNumber The serial number of the NFT to transfer.
    function transferNFT(address token, address sender, address receiver, int64 serialNumber) internal {
        (bool success, bytes memory result) = precompileAddress.call(
            abi.encodeWithSelector(IHTS_NftVotingVault.transferNFT.selector,
            token, sender, receiver, serialNumber));
        require(success, "transferNFT failed");
        int32 responseCode = abi.decode(result, (int32));
        require(responseCode == SUCCESS, "transferNFT error");
    }
}
