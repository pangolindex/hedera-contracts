// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.15;

import { PangoChef } from "./PangoChef.sol";
import { UserPool } from "./PangoChefStructs.sol";
import "./GenericErrors.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title PangoChefUserStorage
 * @author Shung for Pangolin
 * @notice PangoChefStorage holds the storage for each address in a separate contract to allow
 *         users to pay their own contract rent (refer Hedera docs), and allow scaling of the
 *         staking contracts (Hedera contracts have 10 MB state size limit, so we divide it).
 */
contract PangoChefUserStorage is GenericErrors, Ownable {
    using EnumerableSet for EnumerableSet.UintSet;

    /** @notice The set of ids of the pools locked by this pool. */
    mapping(uint256 => EnumerableSet.UintSet) private _lockedPools;

    /** @notice The mapping from poolIds to the user info. */
    mapping(uint256 => UserPool) private _userPools;

    /** @notice The maximum amount of pools that can be locked. This prevents unbounded loop. */
    uint256 private constant MAX_LOCK_COUNT = 10;

    function userPools(uint256 poolId) external view returns (UserPool memory) {
        return _userPools[poolId];
    }

    function lockedPools(uint256 poolId) external view returns (uint256[] memory) {
        return _lockedPools[poolId].values();
    }

    function updateUserPool(uint256 poolId, UserPool calldata userPool) external onlyOwner {
        _userPools[poolId] = userPool;
    }

    function deleteUserPool(uint256 poolId) external onlyOwner {
        delete _userPools[poolId];
    }

    function incrementLock(uint256 harvestPoolId, uint256 compoundPoolId) external onlyOwner {
        // Only increment lock if the user is not already locking the pool.
        if (_lockedPools[harvestPoolId].add(compoundPoolId))
            ++_userPools[compoundPoolId].lockCount;

        if (_lockedPools[harvestPoolId].length() > MAX_LOCK_COUNT) revert OutOfBounds();
    }

    function decrementLock(uint256 withdrawPoolId) external onlyOwner {
        for (
            uint256 lastIndex = _lockedPools[withdrawPoolId].length();
            lastIndex != 0;
        ) {
            unchecked {
                --lastIndex;
            }
            uint256 lockedPoolId = _lockedPools[withdrawPoolId].at(lastIndex);
            if (_lockedPools[withdrawPoolId].remove(lockedPoolId)) {
                --_userPools[lockedPoolId].lockCount; // must always execute
            }
        }
    }

    /** @notice Allow user to withdraw HBAR as they are responsible for managing rent payments */
    function withdraw(uint256 amount, address to) external {
        address userStorageContract = PangoChef(owner()).getUserStorageContract(msg.sender);
        require(userStorageContract == address(this), "Unpriveleged user");
        to.call{ value: amount }("");
    }
}
