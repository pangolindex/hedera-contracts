pragma solidity >=0.8.0 <0.9.0;

import "./storage/ProposalStorage.sol";
import "./storage/ReceiptStorage.sol";

// SPDX-License-Identifier: MIT
abstract contract GovernorPangoAssistant {
    /**
     * @notice Creates a new proposal storage contract
     * @dev Returns the 0x0 address when a proposal storage contract has already been created
     */
    function createProposal(uint64 proposalId) internal returns (address) {
        return _create2(
            keccak256(abi.encodePacked(proposalId)),
            abi.encodePacked(type(ProposalStorage).creationCode, abi.encode(msg.sender))
        );
    }

    function locateProposal(uint64 proposalId) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            keccak256(abi.encodePacked(proposalId)),
            keccak256(abi.encodePacked(type(ProposalStorage).creationCode, abi.encode(address(this))))
        ));
        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Creates a new receipt contract
     * @dev Returns the 0x0 address when a receipt storage contract has already been created
     */
    function createReceipt(uint64 proposalId, int64 nftId) internal returns (address) {
        return _create2(
            keccak256(abi.encodePacked(proposalId, nftId)),
            abi.encodePacked(type(ReceiptStorage).creationCode, abi.encode(msg.sender))
        );
    }

    function locateReceipt(uint64 proposalId, int64 nftId) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            keccak256(abi.encodePacked(proposalId, nftId)),
            keccak256(abi.encodePacked(type(ReceiptStorage).creationCode, abi.encode(address(this))))
        ));
        return address(uint160(uint256(hash)));
    }

    /**
     * @dev When utilizing create2 via assembly, failing calls will return the 0x0 address
     * @dev Consuming methods must handle this logic gracefully
     */
    function _create2(bytes32 salt, bytes memory bytecode) private returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
    }
}
