// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IHTS {
    function associateToken(address account, address token) external returns (int64 responseCode);
    function transferToken(
        address token,
        address sender,
        address recipient,
        int64 amount
    ) external returns (int64 responseCode);
}

contract Merkledrop is Ownable, Pausable {
    IHTS private HTS = IHTS(address(0x167));

    address public immutable REWARD_HTS;

    mapping(address => uint96) public claimedAmounts;
    bytes32 public merkleRoot;

    event Claimed(address indexed from, address indexed to, uint96 indexed amount);
    event MerkleRootSet(bytes32 indexed newMerkleRoot);

    error NothingToClaim();
    error InvalidProof();
    error TransferFailed();
    error NoMerkleRoot();

    constructor(address airdropTokenHTS, address initialOwner) {
        require(initialOwner != address(0), "invalid initial owner");

        int64 responseCode = HTS.associateToken(address(this), airdropTokenHTS);
        require(responseCode == 22, "unknown association code");

        REWARD_HTS = airdropTokenHTS;
        _transferOwnership(initialOwner);
        _pause();
    }

    function claim(
        uint96 amount,
        bytes32[] calldata merkleProof
    ) external {
        claimTo(msg.sender, amount, merkleProof);
    }

    function claimTo(
        address to,
        uint96 amount,
        bytes32[] calldata merkleProof
    ) public whenNotPaused {
        uint96 previouslyClaimed = claimedAmounts[msg.sender];
        if (previouslyClaimed >= amount) revert NothingToClaim();

        bytes32 merkleNode = bytes32(abi.encodePacked(msg.sender, amount));
        if (!MerkleProof.verify(merkleProof, merkleRoot, merkleNode)) revert InvalidProof();

        claimedAmounts[msg.sender] = amount;
        unchecked {
            amount -= previouslyClaimed;
        }
        IERC20(REWARD_HTS).transfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    function setMerkleRoot(bytes32 newMerkleRoot) external whenPaused onlyOwner {
        merkleRoot = newMerkleRoot;
        emit MerkleRootSet(newMerkleRoot);
    }

    function recover(address token, uint256 amount) external whenPaused onlyOwner {
        IERC20(token).transfer(msg.sender, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        if (merkleRoot == 0x00) revert NoMerkleRoot();
        _unpause();
    }
}
