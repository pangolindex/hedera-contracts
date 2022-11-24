// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.15;

import "./PangolinStakingPositionsStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PangolinStakingPositionsStorage is Ownable {

    /** @notice The mapping of position identifiers to their properties. */
    mapping(uint256 => Position) private _positions;

    function positions(uint256 positionId) external view returns (Position memory) {
        return _positions[positionId];
    }

    function updatePosition(uint256 positionId, Position calldata position) external onlyOwner {
        _positions[positionId] = position;
    }

    function deletePosition(uint256 positionId) external onlyOwner {
        delete _positions[positionId];
    }
}
