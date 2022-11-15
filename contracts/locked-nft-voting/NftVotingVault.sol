pragma solidity >=0.8.0;

import "./interfaces/INftVotingVault.sol";
import "./interfaces/IPangolinStakingPositions.sol";
import "./precompiles/IHTS_NftVotingVault.sol";
import "./precompiles/HTS_NftVotingVault.sol";

// SPDX-License-Identifier: MIT
contract NftVotingVault is INftVotingVault, HTS_NftVotingVault {

    address public immutable STAKING_NFT;
    address public immutable STAKING_CONTRACT;
    address public immutable RECEIPT_NFT;

    address public immutable DEPLOYER;
    address public GOVERNOR;

    struct ReceiptMetadata {
        int64 nftId;
        uint40 unlock;
        // @dev Used as a remedy should multiple proposals occur with the same voting period
        uint64 lastProposalVoted;
    }

    error InvalidId();
    error InvalidOwner();
    error InsufficientVotingPower();
    error Frozen();
    error OnlyGovernor();
    error OnlyDeployer();
    error GovernorAlreadySet();

    modifier onlyGov() {
        if (msg.sender != GOVERNOR) revert OnlyGovernor();
        _;
    }

    constructor(
        address stakingContract,
        address stakingNft
    ) payable {
        IHTS_NftVotingVault.HederaToken memory token;
        token.name = "Pangolin Governance Receipt";
        token.symbol = "pVOTE";
        token.treasury = address(this);

        IHTS_NftVotingVault.Expiry memory expiry;
        expiry.autoRenewAccount = address(this);
        expiry.autoRenewPeriod = 90 days;
        token.expiry = expiry;

        IHTS_NftVotingVault.TokenKey[] memory keys = new IHTS_NftVotingVault.TokenKey[](1);
        uint256 KeyType_SUPPLY = 16;
        IHTS_NftVotingVault.KeyValue memory keyValue;
        keyValue.inheritAccountKey = true;
        keys[0] = IHTS_NftVotingVault.TokenKey(KeyType_SUPPLY, keyValue);
        token.tokenKeys = keys;

        address receiptNft = HTS_NftVotingVault.createNonFungibleToken(token);

        HTS_NftVotingVault.associateToken(address(this), stakingNft);

        STAKING_CONTRACT = stakingContract;
        STAKING_NFT = stakingNft;
        RECEIPT_NFT = receiptNft;
        DEPLOYER = msg.sender;
    }

    function unfreeze(int64 receiptId) external {
        IHTS_NftVotingVault.NonFungibleTokenInfo memory receiptInfo = _getInfo(RECEIPT_NFT, receiptId);
        if (receiptInfo.ownerId != msg.sender) revert InvalidOwner();

        ReceiptMetadata memory receiptMetadata = abi.decode(receiptInfo.metadata, (ReceiptMetadata));
        if (block.timestamp <= receiptMetadata.unlock) revert Frozen();

        _import(RECEIPT_NFT, receiptId, msg.sender);
        _burnReceipt(receiptId);
        _export(STAKING_NFT, receiptMetadata.nftId, msg.sender);
    }

    function voteWithNft(uint64 proposalId, int64 nftId, uint40 voteStart, uint40 voteEnd, address owner) external onlyGov returns (uint96 votes, int64 receiptId) {
        votes = getVotesFromNft(nftId, voteStart, owner);
        if (votes == 0) revert InsufficientVotingPower();
        receiptId = _freeze(nftId, voteEnd, proposalId, owner);
    }

    function voteWithReceipt(uint64 proposalId, int64 receiptId, uint40 voteStart, uint40 voteEnd, address owner) external onlyGov returns (uint96 votes, int64 newReceiptId) {
        votes = getVotesFromReceipt(receiptId, voteStart, voteEnd, proposalId, owner);
        if (votes == 0) revert InsufficientVotingPower();
        newReceiptId = _refreeze(receiptId, voteEnd, proposalId, owner);
    }

    // @dev This would be a view method if HTS_NftVotingVault.getNonFungibleTokenInfo() was marked as such
    function getVotesFromReceipt(int64 receiptId, uint40 voteStart, uint40 voteEnd, uint64 proposalId, address owner) public returns (uint96 votes) {
        IHTS_NftVotingVault.NonFungibleTokenInfo memory receiptInfo = _getInfo(RECEIPT_NFT, receiptId);
        if (receiptInfo.ownerId != owner) revert InvalidOwner();

        ReceiptMetadata memory receiptMetadata = abi.decode(receiptInfo.metadata, (ReceiptMetadata));
        if (receiptMetadata.unlock < voteEnd) {
            return getVotesFromNft(receiptMetadata.nftId, voteStart, address(this)); // NFT is NOT locked during voting
        } else if (receiptMetadata.unlock == voteEnd && receiptMetadata.lastProposalVoted < proposalId) {
            return getVotesFromNft(receiptMetadata.nftId, voteStart, address(this)); // NFT is locked (from another equivalent vote period) during voting
        } else {
            return 0; // NFT is locked during voting
        }
    }

    // @dev This would be a view method if HTS_NftVotingVault.getNonFungibleTokenInfo was marked as such
    function getVotesFromNft(int64 nftId, uint40 voteStart, address owner) public returns (uint96 votes) {
        IHTS_NftVotingVault.NonFungibleTokenInfo memory ballotInfo = _getInfo(STAKING_NFT, nftId);
        if (ballotInfo.ownerId != owner) revert InvalidOwner();

        if (nftId == 0) revert InvalidId();
        IPangolinStakingPositions.Position memory position = IPangolinStakingPositions(STAKING_CONTRACT).positions(uint256(uint64(nftId)));
        if (position.lastUpdate < voteStart) {
            return position.valueVariables.balance; // NFT was NOT updated after voting began
        } else {
            return 0; // NFT was updated after voting began
        }
    }

    function freeze(int64 nftId, uint40 expiration, uint64 proposalId, address owner) external onlyGov returns (int64 receiptId) {
        return _freeze(nftId, expiration, proposalId, owner);
    }

    function _freeze(int64 nftId, uint40 expiration, uint64 proposalId, address owner) private returns (int64 receiptId) {
        IHTS_NftVotingVault.NonFungibleTokenInfo memory ballotInfo = _getInfo(STAKING_NFT, nftId);
        if (ballotInfo.ownerId != owner) revert InvalidOwner();

        _import(STAKING_NFT, nftId, owner);
        receiptId = _mintReceipt(ReceiptMetadata({ nftId: nftId, unlock: expiration, lastProposalVoted: proposalId }));
        _export(RECEIPT_NFT, receiptId, owner);
    }

    function _refreeze(int64 receiptId, uint40 expiration, uint64 proposalId, address owner) private returns (int64 newReceiptId) {
        IHTS_NftVotingVault.NonFungibleTokenInfo memory receiptInfo = _getInfo(RECEIPT_NFT, receiptId);
        if (receiptInfo.ownerId != owner) revert InvalidOwner();

        ReceiptMetadata memory receiptMetadata = abi.decode(receiptInfo.metadata, (ReceiptMetadata));
        if (expiration < receiptMetadata.unlock) revert Frozen();

        _import(RECEIPT_NFT, receiptId, owner);
        _burnReceipt(receiptId);
        newReceiptId = _mintReceipt(ReceiptMetadata({ nftId: receiptMetadata.nftId, unlock: expiration, lastProposalVoted: proposalId }));
        _export(RECEIPT_NFT, newReceiptId, owner);
    }

    function _import(address token, int64 serialId, address owner) private {
        HTS_NftVotingVault.transferNFT(token, owner, address(this), serialId);
    }

    function _export(address token, int64 serialId, address owner) private {
        HTS_NftVotingVault.transferNFT(token, address(this), owner, serialId);
    }

    function _mintReceipt(ReceiptMetadata memory metadata) private returns (int64 serialNumber) {
        bytes[] memory encodedMetadata = new bytes[](1);
        encodedMetadata[0] = abi.encode(metadata);

        (, int64[] memory serialNumbers) = HTS_NftVotingVault.mintToken(RECEIPT_NFT, 0, encodedMetadata);
        return serialNumbers[0];
    }

    function _burnReceipt(int64 receiptId) private {
        int64[] memory serialIds = new int64[](1);
        serialIds[0] = receiptId;
        HTS_NftVotingVault.burnToken(RECEIPT_NFT, 0, serialIds);
    }

    function _getInfo(address token, int64 serialId) private returns (IHTS_NftVotingVault.NonFungibleTokenInfo memory tokenInfo) {
        tokenInfo = HTS_NftVotingVault.getNonFungibleTokenInfo(token, serialId);
    }

    function setGovernor(address governor) external {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        if (GOVERNOR != address(0)) revert GovernorAlreadySet();
        GOVERNOR = governor;
    }

}
