// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.15;

import { PangoChef } from "./PangoChef.sol";
import { UserPool } from "./PangoChefStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PangoChefUserStorage
 * @author Shung for Pangolin
 * @notice PangoChefStorage holds the storage for each address in a separate contract to allow
 *         users to pay their own contract rent (refer Hedera docs), and allow scaling of the
 *         staking contracts (Hedera contracts have 10 MB state size limit, so we divide it).
 */
contract PangoChefUserStorage is Ownable {
    /**
     * @notice The number of pools the user has that are locking the pool zero. User can only
     *         withdraw from pool zero if the lock count is zero.
     */
    uint256 public poolZeroLockCount;

    /** @notice The mapping from poolIds to the user info. */
    mapping(uint256 => UserPool) private _userPools;

    function userPools(uint256 poolId) external view returns (UserPool memory) {
        return _userPools[poolId];
    }

    function updateUserPool(uint256 poolId, UserPool calldata userPool) external onlyOwner {
        _userPools[poolId] = userPool;
    }

    function deleteUserPool(uint256 poolId) external onlyOwner {
        delete _userPools[poolId];
    }

    function incrementLock() external onlyOwner {
        unchecked {
            ++poolZeroLockCount;
        }
    }

    function decrementLock() external onlyOwner {
        --poolZeroLockCount;
    }

    /** @notice Allow user to withdraw HBAR as they are responsible for managing rent payments */
    function withdraw(uint256 amount, address to) external {
        address userStorageContract = PangoChef(owner()).getUserStorageContract(msg.sender);
        require(userStorageContract == address(this), "Unpriveleged user");
        to.call{ value: amount }("");
    }
}
