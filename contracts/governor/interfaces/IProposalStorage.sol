pragma solidity >=0.8.0;

// SPDX-License-Identifier: MIT
interface IProposalStorage {
    struct Proposal {
        /// @notice the ordered list of target addresses for calls to be made
        address[] targets;

        /// @notice The ordered list of values (i.e. msg.value) to be passed to the calls to be made
        uint256[] values;

        /// @notice The ordered list of function signatures to be called
        string[] signatures;

        /// @notice The ordered list of calldata to be passed to each call
        bytes[] calldatas;

        /// @notice The NFT which provided the voting weight for this proposal
        int64 proposer;

        /// @notice Current number of votes in favor of this proposal
        uint96 forVotes;

        /// @notice Current number of votes in opposition to this proposal
        uint96 againstVotes;

        /// @notice The timestamp at which voting begins: holders must delegate their votes prior to this time
        uint40 startTime;

        /// @notice The timestamp at which voting ends: votes must be cast prior to this time
        uint40 endTime;

        /// @notice The timestamp that the proposal will be available for execution, set once the vote succeeds
        uint40 eta;

        /// @notice Flag marking whether the proposal has been executed
        bool executed;

        /// @notice Flag marking whether the proposal has been canceled
        bool canceled;
    }
    function ADMIN() external view returns (address);
    function init(IProposalStorage.Proposal memory) external;
    function getProposal() external view returns (IProposalStorage.Proposal memory);
    function setCanceled() external;
    function castVotes(uint96 votes, bool support) external;
    function setEta(uint40 eta) external;
    function setExecuted() external;
}