pragma solidity >=0.8.0 <0.9.0;

import "./interfaces/IGovernorAssistant.sol";
import "./storage/ProposalStorage.sol";
import "./storage/ReceiptStorage.sol";

// SPDX-License-Identifier: MIT
contract GovernorAssistant is IGovernorAssistant {
    function createProposal(uint64 proposalId) external returns (address) {
        return _create2(
            keccak256(abi.encodePacked(proposalId)),
            abi.encodePacked(type(ProposalStorage).creationCode, abi.encode(msg.sender))
        );
    }

    function locateProposal(address deployer, uint64 proposalId) external view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            keccak256(abi.encodePacked(proposalId)),
            keccak256(abi.encodePacked(type(ProposalStorage).creationCode, abi.encode(deployer)))
        ));
        return address(uint160(uint256(hash)));
    }

    function createReceipt(uint64 proposalId, int64 nftId) external returns (address) {
        return _create2(
            keccak256(abi.encodePacked(proposalId, nftId)),
            abi.encodePacked(type(ReceiptStorage).creationCode, abi.encode(msg.sender))
        );
    }

    function locateReceipt(address deployer, uint64 proposalId, int64 nftId) external view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            keccak256(abi.encodePacked(proposalId, nftId)),
            keccak256(abi.encodePacked(type(ReceiptStorage).creationCode, abi.encode(deployer)))
        ));
        return address(uint160(uint256(hash)));
    }

    function _create2(bytes32 salt, bytes memory bytecode) private returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
    }
}
