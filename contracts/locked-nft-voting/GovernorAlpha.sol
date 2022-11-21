pragma solidity =0.8.15;

import "./interfaces/INftVotingVault.sol";
import "./interfaces/ITimelock.sol";

// SPDX-License-Identifier: MIT

/**
 * @title Pangolin Locked NFT Voting
 *
 * @notice Locked NFT Governance is an adaptation of Compound's GovernorAlpha intended to work within the
 *         constraints of Hedera. Voting weight is derived from NFTs utilizing the SAR algorithm where the
 *         voting weight is the quantity of the staked asset. In this paradigm, voters are denoted by NFT
 *         serial IDs instead of voter addresses. A typical user can vote multiple times (once per NFT owned).
 *         After casting a vote, the NFT will be placed into escrow until the voting period has concluded and
 *         a receipt NFT will be issued which can be used to claim the original NFT again after voting concludes.
 *         This receipt NFT can also be used to vote on other concurrent proposals and will utilize the same
 *         underlying voting weight of the originally locked NFT and extend the escrow duration.
 *
 * @dev In the scenario where multiple proposals are created in the same block, voters must vote on them in the
 *      same order they were created (ex. #7, then #8, then #9) as voting on one proposal will invalidate the NFT
 *      from voting on previous proposals.
 *
 * @dev State growth can occur under the `proposals` but the frequency proposals can be created is limited by
 *      the PROPOSAL_THRESHOLD and combination of VOTING_DELAY and VOTING_PERIOD.
 */
contract LockedNFTGovernor {
    /// @notice The delay before voting on a proposal may take place, once proposed
    uint40 public constant VOTING_DELAY = 1 days;

    /// @notice The duration of voting on a proposal, in seconds
    uint40 public constant VOTING_PERIOD = 3 days;

    /// @notice The number of votes required in order for a voter to become a proposer
    uint256 public immutable PROPOSAL_THRESHOLD;

    /// @notice The address of the Pangolin Protocol Timelock
    ITimelock public immutable timelock;

    /// @notice The address of the vault used to freeze NFTs
    INftVotingVault public immutable nftVault;

    /// @notice The address of the Governor Guardian used for initializing Timelock
    address public guardian;

    /// @notice The total number of proposals
    uint256 public proposalCount;

    struct Proposal {
        /// @notice the ordered list of target addresses for calls to be made
        address[] targets;

        /// @notice The ordered list of values (i.e. msg.value) to be passed to the calls to be made
        uint256[] values;

        /// @notice The ordered list of function signatures to be called
        string[] signatures;

        /// @notice The ordered list of calldata to be passed to each call
        bytes[] calldatas;

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

        /// @notice Flag marking whether the proposal has been canceled
        bool canceled;

        /// @notice Flag marking whether the proposal has been executed
        bool executed;

        /// @notice Proposer who created the proposal using an NFT
        address proposer;
    }

    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    /// @notice The official record of all proposals ever proposed
    mapping (uint256 => Proposal) public proposals;

    event ProposalCreated(uint64 id, address[] targets, uint256[] values, string[] signatures, bytes[] calldatas, uint40 startTime, uint40 endTime, string description);
    event VoteCast(address voter, int64 nftId, uint64 proposalId, bool support, uint96 votes, int64 receiptId);
    event ProposalQueued(uint64 id, uint40 eta);
    event ProposalCanceled(uint64 id);
    event ProposalExecuted(uint64 id);

    constructor(
        address _timelock,
        address _guardian,
        uint256 _threshold,
        address _INftVotingVault
    ) {
        timelock = ITimelock(_timelock);
        guardian = _guardian;
        PROPOSAL_THRESHOLD = _threshold;
        nftVault = INftVotingVault(_INftVotingVault);
    }

    /// @dev Accept HBAR for rent
    receive() external payable {}

    /**
     * @dev Create a new proposal
     *      Requires voting power greater than PROPOSAL_THRESHOLD
     *      The NFT must be owned by msg.sender and not locked in the vault
     *      The proposer will have the NFT locked without contributing a for/against vote
     * @param targets - Target contracts
     * @param values - AVAX values
     * @param signatures - Method signatures
     * @param calldatas - Encoded parameter data
     * @param description - Friendly description
     * @param serialId - NFT ID to use voting weight of
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description,
        int64 serialId
    ) external returns (uint64 proposalId, int64 receiptId) {
        require(targets.length == values.length && targets.length == signatures.length && targets.length == calldatas.length, "args length mismatch");
        require(targets.length > 0, "must provide actions");
        require(targets.length <= 10, "too many actions");

        uint40 startTime = uint40(block.timestamp) + VOTING_DELAY;
        uint40 endTime = startTime + VOTING_PERIOD;

        uint96 votes = nftVault.getVotesFromNft(serialId, startTime, msg.sender);
        require(votes > PROPOSAL_THRESHOLD, "proposer votes below proposal threshold");

        Proposal memory newProposal;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.startTime = startTime;
        newProposal.endTime = endTime;
        newProposal.proposer = msg.sender;

        proposalId = uint64(++proposalCount);
        proposals[proposalId] = newProposal;

        receiptId = nftVault.freeze(serialId, endTime, proposalId, msg.sender);

        emit ProposalCreated(proposalId, targets, values, signatures, calldatas, startTime, endTime, description);
    }

    /**
     * @dev Queue a passed proposal into the timelock
     *      Requires the proposal status is SUCCEEDED
     * @param proposalId - Proposal id to queue
     */
    function queue(uint64 proposalId) public {
        Proposal storage proposal = proposals[proposalId];
        require(_state(proposal) == ProposalState.Succeeded, "proposal must be Succeeded");
        uint40 eta = uint40(block.timestamp + timelock.delay());
        proposal.eta = eta;
        for (uint256 i; i < proposal.targets.length; ++i) {
            _queueOrRevert(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], eta);
        }
        emit ProposalQueued(proposalId, eta);
    }

    function _queueOrRevert(address target, uint256 value, string memory signature, bytes memory data, uint40 eta) private {
        require(!timelock.queuedTransactions(keccak256(abi.encode(target, value, signature, data, eta))), "proposal action already queued");
        timelock.queueTransaction(target, value, signature, data, eta);
    }

    /**
     * @dev Execute a proposal already queued in the timelock
     *      Requires the proposal status is QUEUED
     *      Requires the proposal has been sufficiently queued in the timelock
     * @param proposalId - Proposal id to execute
     */
    function execute(uint64 proposalId) external payable {
        Proposal storage proposal = proposals[proposalId];
        require(_state(proposal) == ProposalState.Queued, "proposal must be Queued");

        proposal.executed = true;

        for (uint256 i; i < proposal.targets.length; ++i) {
            timelock.executeTransaction{value: proposal.values[i]}(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], proposal.eta);
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Cancels a proposal
     *      Requires the proposal status is PENDING
     *      Only the proposer can cancel the proposal
     * @param proposalId - Proposal id to cancel
     */
    function cancel(uint64 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(msg.sender == proposal.proposer, "only proposer can cancel");
        require(_state(proposal) == ProposalState.Pending, "proposal must be Pending");

        proposal.canceled = true;

        for (uint256 i; i < proposal.targets.length; ++i) {
            timelock.cancelTransaction(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], proposal.eta);
        }

        emit ProposalCanceled(proposalId);
    }

    /**
     * @dev Cancels a proposal
     *      Requires the proposal status is PENDING
     *      Only the proposer can cancel the proposal
     * @param proposalId - Proposal id to cancel
     */
    function getActions(uint64 proposalId) external view returns (address[] memory targets, uint[] memory values, string[] memory signatures, bytes[] memory calldatas) {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    /**
     * @dev Convenience method to obtain the status of a proposal
     * @param proposalId - Proposal id to query
     */
    function state(uint64 proposalId) external view returns (ProposalState) {
        require(proposalId <= proposalCount && proposalId > 0, "invalid proposal id");
        Proposal storage proposal = proposals[proposalId];
        return _state(proposal);
    }

    function _state(Proposal storage proposal) private view returns (ProposalState) {
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.timestamp <= proposal.startTime) {
            return ProposalState.Pending;
        } else if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        } else if (proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Defeated;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (block.timestamp >= proposal.eta + timelock.GRACE_PERIOD()) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    /**
     * @dev Cast a vote using voting power from an owned NFT
     *      Requires the proposal status is ACTIVE
     *      Voting weight will be pulled from the NFT and it will be locked for the voting duration
     * @param proposalId - Proposal id to vote on
     * @param support - True for yay vote and false for nay vote
     * @param serialId - NFT id to use voting weight and to lock
     */
    function castVoteViaNft(uint64 proposalId, bool support, int64 serialId) external returns (int64) {
        Proposal storage proposal = proposals[proposalId];
        require(_state(proposal) == ProposalState.Active, "voting is closed");

        (uint96 votes, int64 receiptId) = nftVault.voteWithNft(proposalId, serialId, proposal.startTime, proposal.endTime, msg.sender);

        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }

        emit VoteCast(msg.sender, serialId, proposalId, support, votes, receiptId);

        return receiptId;
    }

    /**
     * @dev Cast a vote using voting power from an already locked NFT
     *      Requires the proposal status is ACTIVE
     *      Voting weight will be pulled from the locked NFT and the lock will be extended for the voting duration
     * @param proposalId - Proposal id to vote on
     * @param support - True for yay vote and false for nay vote
     * @param serialId - Receipt id (representing locked NFT) to use voting weight and to re-lock
     */
    function castVoteViaReceipt(uint64 proposalId, bool support, int64 serialId) external returns (int64) {
        Proposal storage proposal = proposals[proposalId];
        require(_state(proposal) == ProposalState.Active, "voting is closed");

        (uint96 votes, int64 receiptId) = nftVault.voteWithReceipt(proposalId, serialId, proposal.startTime, proposal.endTime, msg.sender);

        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }

        emit VoteCast(msg.sender, serialId, proposalId, support, votes, receiptId);

        return receiptId;
    }

    function __acceptAdmin() external {
        require(msg.sender == guardian, "sender must be gov guardian");
        timelock.acceptAdmin();
    }

    function __abdicate() external {
        require(msg.sender == guardian, "sender must be gov guardian");
        guardian = address(0);
    }

    function __queueSetTimelockPendingAdmin(address newPendingAdmin, uint256 eta) external {
        require(msg.sender == guardian, "sender must be gov guardian");
        timelock.queueTransaction(address(timelock), 0, "setPendingAdmin(address)", abi.encode(newPendingAdmin), eta);
    }

    function __executeSetTimelockPendingAdmin(address newPendingAdmin, uint256 eta) external {
        require(msg.sender == guardian, "sender must be gov guardian");
        timelock.executeTransaction(address(timelock), 0, "setPendingAdmin(address)", abi.encode(newPendingAdmin), eta);
    }
}

