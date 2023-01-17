pragma solidity >=0.8.0 <0.9.0;

// SPDX-License-Identifier: MIT
interface IGovernorAssistant {
    function createProposal(uint64 proposalId) external returns (address);
    function locateProposal(address deployer, uint64 proposalId) external view returns (address);
    function createReceipt(uint64 proposalId, int64 nftId) external returns (address);
    function locateReceipt(address deployer, uint64 proposalId, int64 nftId) external view returns (address);
}