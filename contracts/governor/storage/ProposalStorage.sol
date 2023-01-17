pragma solidity >=0.8.0;

import "../interfaces/IProposalStorage.sol";

// SPDX-License-Identifier: MIT
/*
 * @notice Storage contract for proposal data to avoid contract state growth.
 * @dev This is intended to be used with GovernorAssistant as the admin.
 */
contract ProposalStorage is IProposalStorage {
    IProposalStorage.Proposal private proposal;
    address public immutable ADMIN;

    error AccessDenied();

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert AccessDenied();
        _;
    }

    /// @dev For reception of rent if needed
    receive() external payable {}

    /*
     * @notice Allows the deployer to safely delegate write access.
     */
    constructor(address admin) {
        ADMIN = admin;
    }

    /*
     * @notice Initializes a storage contract with proposal data.
     * @dev Admin contract must handle protection against double initialization.
     */
    function init(IProposalStorage.Proposal memory _proposal) external onlyAdmin {
        proposal = _proposal;
    }

    function getProposal() external view returns (IProposalStorage.Proposal memory) {
        return proposal;
    }

    function setCanceled() external onlyAdmin {
        proposal.canceled = true;
    }

    function castVotes(uint96 votes, bool support) external onlyAdmin {
        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }
    }

    function setEta(uint40 eta) external onlyAdmin {
        proposal.eta = eta;
    }

    function setExecuted() external onlyAdmin {
        proposal.executed = true;
    }
}

