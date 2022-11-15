pragma solidity >=0.8.0;

// SPDX-License-Identifier: MIT
interface INftVotingVault {
    function unfreeze(int64 receiptId) external;
    function freeze(int64 nftId, uint40 expiration, uint64 proposalId, address owner) external returns (int64 receiptId);
    function getVotesFromReceipt(int64 receiptId, uint40 voteStart, uint40 voteEnd, uint64 proposalId, address owner) external returns (uint96 votes);
    function voteWithNft(uint64 proposalId, int64 nftId, uint40 voteStart, uint40 voteEnd, address owner) external returns (uint96 votes, int64 receiptId);
    function voteWithReceipt(uint64 proposalId, int64 receiptId, uint40 voteStart, uint40 voteEnd, address owner) external returns (uint96 votes, int64 newReceiptId);
    function getVotesFromNft(int64 nftId, uint40 voteStart, address owner) external returns (uint96 votes);
}
