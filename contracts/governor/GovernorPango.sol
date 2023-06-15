pragma solidity =0.8.15;

import "./interfaces/IPangolinStakingPositions.sol";
import "./interfaces/IProposalStorage.sol";
import "./interfaces/ITimelock.sol";

import "./GovernorPangoAssistant.sol";
import "./precompiles/HTS_Governor.sol";

// SPDX-License-Identifier: MIT
/*
 * @notice GovernorPango is an adaptation of GovernorAlpha intended to work with PangolinStakingPositions NFTs
 *         on the Hedera blockchain. The proposal lifecycle is the same as GovernorAlpha but additional
 *         restrictions are imposed:
 *
 *         1) Proposers must hold an NFT that has not been modified for the duration of 1+ proposal lifecycle
 *         2) The voting power of an NFT used for proposing will be invalid for the duration of one proposal lifecycle
 *         3) Voters must own an NFT that has not been modified after the voting period starts
 *         4) An NFT cannot be used for voting on the same proposal multiple times, regardless of ownership
 *         5) The proposer is always allowed to cancel the proposal before voting begins
 */
contract GovernorPango is GovernorPangoAssistant, HTS_Governor {
    /// @notice The delay before voting on a proposal may take place, once proposed
    /// @dev Can be changed via vote within the range: [1 days, 7 days]
    uint40 public VOTING_DELAY = 1 days;

    /// @notice The duration of voting on a proposal, in seconds
    /// @dev Can be changed via vote within the range: [3 days, 30 days]
    uint40 public VOTING_PERIOD = 3 days;

    /// @notice The number of votes required in order for a voter to become a proposer
    /// @dev Can be changed via vote within the range: [PROPOSAL_THRESHOLD_MIN, PROPOSAL_THRESHOLD_MAX]
    uint96 public PROPOSAL_THRESHOLD = 2_000_000e8;
    uint96 public constant PROPOSAL_THRESHOLD_MIN = 500_000e8;
    uint96 public constant PROPOSAL_THRESHOLD_MAX = 50_000_000e8;

    /// @notice The address of the timelock
    ITimelock public immutable TIMELOCK;

    /// @notice The HTS NFT representing staked positions ownership
    address public immutable NFT_TOKEN;

    /// @notice The NFT contract containing staked position data
    address public immutable NFT_CONTRACT;

    /// @notice The total number of proposals
    uint256 public proposalCount;

    /// @notice Timestamp when a NFT can be used to propose again
    /// @dev State growth rate is limited by PROPOSAL_THRESHOLD and the lifecycle time of a proposal.
    mapping(int64 => uint40) public proposalTimeout;

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

    event ProposalCreated(uint64 id, address[] targets, uint256[] values, string[] signatures, bytes[] calldatas, uint40 startTime, uint40 endTime, string description);
    event ProposalCanceled(uint64 id);
    event VoteCast(uint64 proposalId, bool support, uint96 votes);
    event ProposalQueued(uint64 id, uint40 eta);
    event ProposalExecuted(uint64 id);
    event ProposalThresholdChanged(uint96 newProposalThreshold);
    event VotingDelayChanged(uint40 newVotingDelay);
    event VotingPeriodChanged(uint40 newVotingPeriod);

    error InvalidAction();
    error InsufficientVotes();
    error IllegalVote();
    error InvalidNFT();
    error InvalidOwner();
    error InvalidState();

    /// @dev For reception of rent if needed
    receive() external payable {}

    constructor(
        address _timelock,
        address _nft,
        address _nftContract
    ) {
        TIMELOCK = ITimelock(_timelock);
        NFT_TOKEN = _nft;
        NFT_CONTRACT = _nftContract;
    }

    /*
     * @dev Proposers must own an NFT with voting power of at least PROPOSAL_THRESHOLD. This NFT must not have been
     *      updated for a duration of 1+ proposal lifecycle before proposing.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description,
        int64 nftId
    ) external returns (uint64 proposalId) {
        if (targets.length != values.length || targets.length != signatures.length || targets.length != calldatas.length) revert InvalidAction();
        if (targets.length > 10) revert InvalidAction();

        _verifyOwnership(nftId);

        uint40 startTime = uint40(block.timestamp) + VOTING_DELAY;
        uint40 endTime = startTime + VOTING_PERIOD;
        uint40 proposalLifeCycleTime = VOTING_DELAY + VOTING_PERIOD + uint40(TIMELOCK.delay()); // Range: [4 days, 67 days]

        // Ensure enough voting power exists and has not been altered recently
        // By using a timestamp predated by the lifecycle of a proposal, spam can be prevented from the same underlying voting power
        if (_getNftValueAt(nftId, uint40(block.timestamp) - proposalLifeCycleTime) < PROPOSAL_THRESHOLD) revert InsufficientVotes();

        // Prevent usage of NFT voting weight to concurrently create proposals
        if (block.timestamp < proposalTimeout[nftId]) revert InsufficientVotes();
        proposalTimeout[nftId] = uint40(block.timestamp) + proposalLifeCycleTime;

        proposalId = uint64(++proposalCount);

        IProposalStorage.Proposal memory newProposal;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.proposer = nftId;
        newProposal.startTime = startTime;
        newProposal.endTime = endTime;

        IProposalStorage(GovernorPangoAssistant.createProposal(proposalId)).init(newProposal);

        emit ProposalCreated(proposalId, targets, values, signatures, calldatas, startTime, endTime, description);
    }

    /*
     * @dev Non-executed proposals can be canceled when the proposer fails to maintain sufficient voting power
     *      Proposals can also be canceled by the owner of the proposal's proposing NFT before voting begins
     */
    function cancel(uint64 proposalId) external {
        address proposalLocation = GovernorPangoAssistant.locateProposal(proposalId);
        IProposalStorage.Proposal memory proposal = IProposalStorage(proposalLocation).getProposal();
        ProposalState proposalState = _state(proposal);
        if (proposalState == ProposalState.Executed) revert InvalidState();

        // Proposals failing to maintain sufficient voting power can be canceled by anybody
        if (_getNftValueAt(proposal.proposer, uint40(block.timestamp)) >= PROPOSAL_THRESHOLD) {
            // Pending proposals maintaining sufficient voting power can only be canceled by the proposer NFT owner
            if (proposalState == ProposalState.Pending) {
                _verifyOwnership(proposal.proposer);
            } else {
                revert InvalidState();
            }
        }

        IProposalStorage(proposalLocation).setCanceled();

        emit ProposalCanceled(proposalId);
    }

    function castVote(uint64 proposalId, bool support, int64 nftId) external {
        address proposalLocation = GovernorPangoAssistant.locateProposal(proposalId);
        IProposalStorage.Proposal memory proposal = IProposalStorage(proposalLocation).getProposal();
        if (_state(proposal) != ProposalState.Active) revert InvalidState();

        _verifyOwnership(nftId);

        // Verify NFT was not updated after voting began
        uint96 votes = _getNftValueAt(nftId, proposal.startTime);
        if (votes == 0) revert InsufficientVotes();

        // Verify NFT can only vote once
        if (GovernorPangoAssistant.createReceipt(proposalId, nftId) == address(0)) revert IllegalVote();

        // Cast vote
        IProposalStorage(proposalLocation).castVotes(votes, support);

        emit VoteCast(proposalId, support, votes);
    }

    function queue(uint64 proposalId) external {
        address proposalLocation = GovernorPangoAssistant.locateProposal(proposalId);
        IProposalStorage.Proposal memory proposal = IProposalStorage(proposalLocation).getProposal();
        if (_state(proposal) != ProposalState.Succeeded) revert InvalidState();

        uint40 eta = uint40(block.timestamp + TIMELOCK.delay());
        IProposalStorage(proposalLocation).setEta(eta);

        uint256 proposalActions = proposal.targets.length;
        for (uint256 i; i < proposalActions;) {
            _queueOrRevert(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], eta);
            unchecked {++i;}
        }

        emit ProposalQueued(proposalId, eta);
    }

    function _queueOrRevert(address target, uint256 value, string memory signature, bytes memory data, uint40 eta) private {
        if (TIMELOCK.queuedTransactions(keccak256(abi.encode(target, value, signature, data, eta)))) revert InvalidState();
        TIMELOCK.queueTransaction(target, value, signature, data, eta);
    }

    function execute(uint64 proposalId) external payable {
        address proposalLocation = GovernorPangoAssistant.locateProposal(proposalId);
        IProposalStorage.Proposal memory proposal = IProposalStorage(proposalLocation).getProposal();
        if (_state(proposal) != ProposalState.Queued) revert InvalidState();

        IProposalStorage(proposalLocation).setExecuted();

        uint256 proposalActions = proposal.targets.length;
        for (uint256 i; i < proposalActions;) {
            TIMELOCK.executeTransaction{value: proposal.values[i]}(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], proposal.eta);
            unchecked {++i;}
        }

        emit ProposalExecuted(proposalId);
    }

    function state(uint64 proposalId) external view returns (ProposalState) {
        return _state(IProposalStorage(GovernorPangoAssistant.locateProposal(proposalId)).getProposal());
    }

    function _state(IProposalStorage.Proposal memory proposal) private view returns (ProposalState) {
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
        } else if (block.timestamp >= proposal.eta + TIMELOCK.GRACE_PERIOD()) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    /*
     * @notice Ensure the NFT is owned by `msg.sender` and revert when not satisfied.
     */
    function _verifyOwnership(int64 nftId) private {
        if (HTS_Governor.getNonFungibleTokenOwner(NFT_TOKEN, nftId) != msg.sender) revert InvalidOwner();
    }

    /*
     * @dev This is how voting power is calculated from the NFT. The NFT must not have been modified after `timestamp`
     *      for the voting power to be valid.
     */
    function _getNftValueAt(int64 nftId, uint40 timestamp) private view returns (uint96) {
        if (nftId <= 0) revert InvalidNFT();
        IPangolinStakingPositions.Position memory position = IPangolinStakingPositions(NFT_CONTRACT).positions(uint256(uint64(nftId)));
        if (position.lastUpdate < timestamp) {
            return position.valueVariables.balance;
        } else {
            return 0;
        }
    }

    function __acceptAdmin() external {
        TIMELOCK.acceptAdmin();
    }

    function __setProposalThreshold(uint96 newProposalThreshold) external {
        if (msg.sender != address(TIMELOCK)) revert InvalidAction();
        if (newProposalThreshold < PROPOSAL_THRESHOLD_MIN) revert InvalidAction();
        if (newProposalThreshold > PROPOSAL_THRESHOLD_MAX) revert InvalidAction();
        PROPOSAL_THRESHOLD = newProposalThreshold;
        emit ProposalThresholdChanged(newProposalThreshold);
    }

    function __setVotingDelay(uint40 newVotingDelay) external {
        if (msg.sender != address(TIMELOCK)) revert InvalidAction();
        if (newVotingDelay < 1 days) revert InvalidAction();
        if (newVotingDelay > 7 days) revert InvalidAction();
        VOTING_DELAY = newVotingDelay;
        emit VotingDelayChanged(newVotingDelay);
    }

    function __setVotingPeriod(uint40 newVotingPeriod) external {
        if (msg.sender != address(TIMELOCK)) revert InvalidAction();
        if (newVotingPeriod < 3 days) revert InvalidAction();
        if (newVotingPeriod > 30 days) revert InvalidAction();
        VOTING_PERIOD = newVotingPeriod;
        emit VotingPeriodChanged(newVotingPeriod);
    }
}
