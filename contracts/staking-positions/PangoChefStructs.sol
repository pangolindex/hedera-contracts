// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.15;

struct ValueVariables {
    // The amount of tokens staked by the user in the pool or total staked in the pool.
    uint104 balance;
    // The sum of each staked token multiplied by its update time.
    uint152 sumOfEntryTimes;
}

struct RewardSummations {
    // Imaginary rewards accrued by a position with `lastUpdate == 0 && balance == 1`. At the
    // end of each interval, the ideal position has a staking duration of `block.timestamp`.
    // Since its balance is one, its “value” equals its staking duration. So, its value
    // is also `block.timestamp` , and for a given reward at an interval, the ideal position
    // accrues `reward * block.timestamp / totalValue`. Refer to `Ideal Position` section of
    // the Proofs on why we need this variable.
    uint256 idealPosition;
    // The sum of `reward/totalValue` of each interval. `totalValue` is the sum of all staked
    // tokens multiplied by their respective staking durations.  On every update, the
    // `rewardPerValue` is incremented by rewards given during that interval divided by the
    // total value, which is average staking duration multiplied by total staked. See proofs.
    uint256 rewardPerValue;
}

struct UserPool {
    // Two variables that specify the share of rewards a user must receive from the pool.
    ValueVariables valueVariables;
    // Summations snapshotted on the last update of the user.
    RewardSummations rewardSummationsPaid;
    // The sum of values (`balance * (block.timestamp - lastUpdate)`) of previous intervals.
    // It is only incremented accordingly when tokens are staked, and it is reset to zero
    // when tokens are withdrawn. Correctly updating this property allows for the staking
    // duration of the existing balance of the user to not restart when staking more tokens.
    // So it allows combining together tokens with differing staking durations. Refer to the
    // `Combined Positions` section of the Proofs on why this works.
    uint152 previousValues;
    // The last time the user info was updated.
    uint48 lastUpdate;
    // When a user uses the rewards of a pool to compound into pool zero, the pool zero gets
    // locked until that pool has its staking duration reset. Otherwise people can exploit
    // the `compoundToPoolZero()` function to harvest rewards of a pool without resetting its
    // staking duration, which would defeat the purpose of using SAR algorithm.
    bool isLockingPoolZero;
    // Last timestamps of low-level call fails, so Rewarder can slash rewards.
    uint48 lastTimeRewarderCallFailed;
    // Rewards of the user gets stashed when user’s summations are updated without
    // harvesting the rewards or without utilizing the rewards in compounding.
    uint96 stashedRewards;
}
