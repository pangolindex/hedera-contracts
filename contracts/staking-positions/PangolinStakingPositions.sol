// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "./PangolinStakingPositionsFunding.sol";
import "./PangolinStakingPositionsStructs.sol";
import { PangolinStakingPositionsStorage } from "./PangolinStakingPositionsStorage.sol";

import "../hts-precompile/HederaResponseCodes.sol";
import "../hts-precompile/HederaTokenService.sol";
import "../hts-precompile/ExpiryHelper.sol";
import "../exchange-rate-precompile/SelfFunding.sol";

/**
 * @title Pangolin Staking Positions
 * @author shung for Pangolin
 *
 * @notice Pangolin Staking Positions is a unique staking solution. It utilizes the Sunshine and
 *         Rainbows (SAR) algorithm, which distributes rewards as a function of balance and staking
 *         duration. See README and the Proofs paper to see how SAR works. In this implementation,
 *         the staking token is the same as the reward token, and staking information is recorded
 *         as positions where each position is an NFT.
 *
 * @dev SAR Algorithm:

 *      SAR allocates a user (or position) the following proportion of any given rewards:
 *
 *      `(balance_position / balance_total) * (stakingDuration_position /
 *      stakingDuration_average)`.
 *
 *      Staking duration is how long a token has been staked. The staking duration of a token
 *      starts when it is staked, restarts when its rewards are harvested, and ends when it is
 *      withdrawn.
 *
 *      We can refer to `balance * stakingDuration` as `value`. Based on this definition, the
 *      formula above can be simplified to `value_position / value_total`.
 *
 *      Although this looks similar to just `balance_position / balance_total`, unlike balance, the
 *      value of every position is constantly changing as a function of time. Therefore, we cannot
 *      simply use the standard staking algorithm (i.e.: Synthetix StakingRewards) for calculating
 *      rewards of users in constant time. A new algorithm had to be invented for this reason.
 *
 *      To understand the algorithm, one must read the Proofs. Then
 *      `_getRewardSummationsIncrementations()` and `_earned()` functions will make sense.
 *
 * @dev Assumptions (not checked to be true):
 *      - `rewardsToken` reverts or returns false on invalid transfers,
 *      - `block.timestamp * totalRewardAdded` fits 128 bits,
 *      - `block.timestamp` is never greater than `2**40 - 1 - 2**32`.
 *
 * @dev Limitations (checked to be true):
 *      - `totalStaked` fits 96 bits.
 *      - `totalRewardAdded` fits 96 bits.
 */
contract PangolinStakingPositions is HederaTokenService, ExpiryHelper, SelfFunding, PangolinStakingPositionsFunding {
    /** @notice The contract that constructs and returns tokenURIs for position tokens. */
    IERC721 public immutable positionsToken;

    /** @notice The struct holding the totalStaked and sumOfEntryTimes. */
    ValueVariables public totalValueVariables;

    /** @notice The variables that govern the reward distribution. */
    RewardSummations public rewardSummationsStored;

    /** @notice The index of the next storage contract to be deployed. */
    uint256 public nextPositionsStorageContractIndex = 0;

    /** @notice The fixed denominator used for storing summations. */
    uint256 private constant PRECISION = 2**128;

    /** @notice Seconds in three months */
    uint256 private constant THREE_MONTHS = 90 days;

    /** @notice The duration the rent should be payed for in advance. */
    uint256 private constant RENT_DOWNPAYMENT_DURATION = THREE_MONTHS * 2; // 6 months

    /** @notice The duration the rent should be payed for in advance. */
    uint256 private constant EVICTION_POINT = THREE_MONTHS; // < ~3 months downpayment remaining

    /** @notice The rent in tinycents for a position for three months. */
    uint256 private constant THREE_MONTHS_RENT = 500_000_000; // 5 cents in tinycents

    /** @notice The rent in tinybars for a position for three months. */
    int64 public rentInTinyBars = -1; // will not use this when negative

    /** @notice The number of positions a storage contract can hold. */
    uint256 private constant STORAGE_SIZE = 2500; // five hundred

    /** @dev The privileged role that can evict positions not paying rent. */
    bytes32 private constant EVICTION_ROLE = keccak256("EVICTION_ROLE");

    /** @notice The event emitted when withdrawing or harvesting from a position. */
    event Withdrawn(uint256 indexed positionId, uint256 indexed amount, uint256 indexed reward);

    /** @notice The event emitted when staking to, minting, or compounding a position. */
    event Staked(uint256 indexed positionId, uint256 indexed amount, uint256 indexed reward);

    /** @notice The event emitted when user is evicted for not paying rent. */
    event Evicted(uint256 indexed positionId, uint256 indexed amount, address indexed owner, address to, bool toOwner);

    event SetRentInTinyBars(bool isDisabled, uint256 rent);

    modifier onlyOwner(uint256 positionId) {
        if (positionsToken.ownerOf(positionId) != msg.sender) revert UnprivilegedCaller();
        _;
    }

    /**
     * @notice Constructor to create and initialize PangolinStakingPositions contract.
     * @param newRewardsToken The token used for both for staking and reward.
     * @param newAdmin The initial owner of the contract.
     */
    constructor(
        address newRewardsToken,
        address newAdmin
    ) payable
        PangolinStakingPositionsFunding(newRewardsToken, newAdmin)
    {
        _grantRole(EVICTION_ROLE, newAdmin);

        // Associate the reward token

        // Associate Hedera native token to this address (i.e.: allow this contract to hold the token).
        int associateResponseCode = associateToken(address(this), newRewardsToken);
        require(associateResponseCode == HederaResponseCodes.SUCCESS, 'Assocation failed');

        // Create the NFT

        // Define the key of this contract.
        IHederaTokenService.KeyValue memory key;
        key.contractId = address(this);

        // Define a supply key which gives this contract minting and burning access.
        IHederaTokenService.TokenKey memory supplyKey;
        supplyKey.keyType = KeyHelper.keyTypes[KeyHelper.KeyType.SUPPLY];
        supplyKey.key = key;

        // Define a wipe key which gives this contract access to directly burn from wallets.
        IHederaTokenService.TokenKey memory wipeKey;
        wipeKey.keyType = KeyHelper.keyTypes[KeyHelper.KeyType.WIPE];
        wipeKey.key = key;

        // Define an admin key which allows this contract to update the memo.
        IHederaTokenService.TokenKey memory adminKey;
        adminKey.keyType = KeyHelper.keyTypes[KeyHelper.KeyType.ADMIN];
        adminKey.key = key;

        // Define the key types used in the token.
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](3);
        keys[0] = supplyKey;
        keys[1] = wipeKey;
        keys[2] = adminKey;

        // Define the token properties.
        IHederaTokenService.HederaToken memory token;
        token.name = "Pangolin Staking Positions";
        token.symbol = "PNG-POS";
        token.treasury = address(this);
        token.memo = "https://static.pangolin.exchange/pangolin-hedera-positions-memo.json";
        token.tokenKeys = keys;
        token.expiry = createAutoRenewExpiry(address(this), 90 days);

        // Create the token.
        (int256 createResponseCode, address tokenAddress) = createNonFungibleToken(token);
        if (createResponseCode != HederaResponseCodes.SUCCESS) revert InvalidType();

        // Set the immutable state variable for the positions token.
        positionsToken = IERC721(tokenAddress);
    }

    /**
     * @notice External function to open a new position to the caller.
     * @param amount The amount of tokens to transfer from the caller to the position.
     * @param positionId The identifier of the newly created position.
     */
    function mint(uint256 amount) external payable returns (uint256 positionId) {
        // Update summations. Note that rewards accumulated when there is no one staking will
        // be lost. But this is only a small risk of value loss when the contract first goes live.
        _updateRewardSummations();

        // Mint the HTS NFT for bookkeeping.
        positionId = _mint();

        // Create the storage contract for the position storage.
        _createPositionsStorageContract(positionId);

        // Use a private function to handle the logic pertaining to depositing into a position.
        _stake(positionId, amount);

        // Get rent amount downpayment for a good long duration.
        _receiveRent(RENT_DOWNPAYMENT_DURATION);
    }

    /**
     * @notice External function to deposit tokens to an existing position.
     * @param amount The amount of tokens to deposit into the position.
     * @param positionId The identifier of the position to deposit the funds into.
     */
    function stake(uint256 positionId, uint256 amount) external payable {
        // Update summations. Note that rewards accumulated when there is no one staking will
        // be lost. But this is only a small risk of value loss when the contract first goes live.
        _updateRewardSummations();

        // Use a private function to handle the logic pertaining to depositing into a position.
        uint256 rentTime = _stake(positionId, amount);

        // Get rent amount for the duration not payed. In other words, topping it up.
        _receiveRent(rentTime);
    }

    /**
     * @notice External function to claim the accrued rewards of a position.
     * @param positionId The identifier of the position to claim the rewards of.
     */
    function harvest(uint256 positionId) external payable {
        // Update summations that govern the reward distribution.
        _updateRewardSummations();

        // Use a private function to handle the logic pertaining to harvesting rewards.
        // `_withdraw` with zero input amount works as harvesting.
        uint256 rentTime = _withdraw(positionId, 0);

        // Get rent amount for the duration not payed. In other words, topping it up.
        _receiveRent(rentTime);
    }

    /**
     * @notice External function to deposit the accrued rewards of a position back to itself.
     * @param positionId The identifier of the position to compound the rewards of.
     */
    function compound(uint256 positionId) external payable {
        // Update summations that govern the reward distribution.
        _updateRewardSummations();

        // Use a private function to handle the logic pertaining to compounding rewards.
        // `_stake` with zero input amount works as compounding.
        uint256 rentTime = _stake(positionId, 0);

        // Get rent amount for the duration not payed. In other words, topping it up.
        _receiveRent(rentTime);
    }

    /**
     * @notice External function to withdraw given amount of staked balance, plus all the accrued
     *         rewards from the position.
     * @param positionId The identifier of the position to withdraw the balance.
     * @param amount The amount of staked tokens, excluding rewards, to withdraw from the position.
     */
    function withdraw(uint256 positionId, uint256 amount) external payable {
        // Update summations that govern the reward distribution.
        _updateRewardSummations();

        // Use a private function to handle the logic pertaining to withdrawing the staked balance.
        uint256 rentTime = _withdraw(positionId, amount);

        // Get rent amount for the duration not payed. In other words, topping it up.
        _receiveRent(rentTime);
    }

    /**
     * @notice External function to close a position by burning the associated NFT.
     * @param positionId The identifier of the position to close.
     */
    function burn(uint256 positionId) external onlyOwner(positionId) {
        // To prevent mistakes, ensure only valueless positions can be burned.
        if (positions(positionId).valueVariables.balance != 0) revert InvalidToken();

        // Burn the associated NFT and delete all position properties.
        _burn(positionId);
    }

    /**
     * @notice External function to exit from a position by forgoing rewards.
     * @param positionId The identifier of the position to exit.
     */
    function emergencyExit(uint256 positionId) external {
        // Do not update summations, because a faulty rewarding algorithm might be the
        // culprit locking the staked balance in the contract. Nonetheless, for consistency, use a
        // private function to handle the logic pertaining to emergency exit.
        _emergencyExit(positionId);
    }

    /**
     * @notice External function to stake to or compound multiple positions.
     * @dev This saves gas by updating summations only once.
     * @param positionIds An array of identifiers of positions to stake to.
     * @param amounts An array of amount of tokens to stake to the corresponding positions.
     */
    function multiStake(uint256[] calldata positionIds, uint256[] calldata amounts) external payable {
        // Update summations only once. Note that rewards accumulated when there is no one
        // staking will be lost. But this is only a small risk of value loss if a reward period
        // during no one staking is followed by staking.
        _updateRewardSummations();

        // Ensure array lengths match.
        uint256 length = positionIds.length;
        if (length != amounts.length) revert MismatchedArrayLengths();

        uint256 rentTime = 0;
        for (uint256 i = 0; i < length; ) {
            rentTime += _stake(positionIds[i], amounts[i]);

            // Counter realistically cannot overflow.
            unchecked {
                ++i;
            }
        }

        // Get rent amount for the duration not payed. In other words, topping it up.
        _receiveRent(rentTime);
    }

    /**
     * @notice External function to withdraw or harvest from multiple positions.
     * @dev This saves gas by updating summations only once.
     * @param positionIds An array of identifiers of positions to withdraw from.
     * @param amounts An array of amount of tokens to withdraw from corresponding positions.
     */
    function multiWithdraw(uint256[] calldata positionIds, uint256[] calldata amounts) external payable {
        // Update summations only once.
        _updateRewardSummations();

        // Ensure array lengths match.
        uint256 length = positionIds.length;
        if (length != amounts.length) revert MismatchedArrayLengths();

        uint256 rentTime = 0;
        for (uint256 i = 0; i < length; ) {
            rentTime = _withdraw(positionIds[i], amounts[i]);

            // Counter realistically cannot overflow.
            unchecked {
                ++i;
            }
        }

        // Get rent amount for the duration not payed. In other words, topping it up.
        _receiveRent(rentTime);
    }

    /**
     * @notice External only-owner function to change the tokenURI.
     * @param memo The URI that holds token memo.
     */
    function setTokenMemo(string memory memo) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (int256 getResponseCode, IHederaTokenService.TokenInfo memory tokenInfo) = getTokenInfo(address(positionsToken));
        if (getResponseCode != HederaResponseCodes.SUCCESS) revert InvalidType();

        tokenInfo.token.memo = memo;

        int256 updateResponseCode = updateTokenInfo(address(positionsToken), tokenInfo.token);
        if (updateResponseCode != HederaResponseCodes.SUCCESS) revert InvalidType();
    }

    function setRentInTinyBars(int64 rent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bool isDisabled = rent < 0;
        rentInTinyBars = rent;
        emit SetRentInTinyBars(isDisabled, isDisabled ? 0 : uint64(rent));
    }

    function withdraw(address to, uint256 amount) external payable onlyRole(DEFAULT_ADMIN_ROLE) {
        to.call{ value: amount }("");
    }

    function evict(uint256[] calldata positionIds, address to) external onlyRole(EVICTION_ROLE) {
        _updateRewardSummations();

        uint256 length = positionIds.length;
        for (uint256 i = 0; i < length; ) {
            uint256 positionId = positionIds[i];
            Position memory position = positions(positionId);

            uint256 rentTime = block.timestamp - position.lastUpdate;
            if (rentTime < EVICTION_POINT) revert TooEarly();

            uint256 amount = position.valueVariables.balance + _positionPendingRewards(position);
            address owner = positionsToken.ownerOf(positionId);

            _burn(positionId);

            // We have to have a fallback because an user might unassociated the reward token.
            bool toOwner;
            try rewardsToken.transfer(owner, amount) returns (bool success) {
                if (!success) {
                    rewardsToken.transfer(to, amount);
                } else {
                    toOwner = true;
                }
            } catch {
                rewardsToken.transfer(to, amount);
            }

            emit Evicted(positionId, amount, owner, to, toOwner);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice External view function to get the reward rate of a position.
     * @dev In SAR, positions have different APRs, unlike other staking algorithms. This external
     *      function clearly demonstrates how the SAR algorithm is supposed to distribute the
     *      rewards based on “value”, which is balance times staking duration. This external
     *      function can be considered as a specification.
     * @param positionId The identifier of the position to check the reward rate of.
     * @return The rewards per second of the position.
     */
    function positionRewardRate(uint256 positionId) external view returns (uint256) {
        // Get totalValue and positionValue.
        uint256 totalValue = _getValue(totalValueVariables);
        uint256 positionValue = _getValue(positions(positionId).valueVariables);

        // Return the rewardRate of the position. Do not revert if totalValue is zero.
        return positionValue == 0 ? 0 : (rewardRate() * positionValue) / totalValue;
    }

    /**
     * @notice External view function to get the accrued rewards of a position. It takes the
     *         pending rewards since lastUpdate into consideration.
     * @param positionId The identifier of the position to check the accrued rewards of.
     * @return The amount of rewards that have been accrued in the position.
     */
    function positionPendingRewards(uint256 positionId) external view returns (uint256) {
        // Create a storage pointer for the position.
        Position memory position = positions(positionId);

        // Get the delta of summations. Use incremented `rewardSummationsStored` based on the
        // pending rewards.
        RewardSummations memory deltaRewardSummations = _getDeltaRewardSummations(position, true);

        // Return the pending rewards of the position based on the difference in rewardSummations.
        return _earned(deltaRewardSummations, position);
    }

    function getPositionsStorageContract(uint256 positionId) external view returns (address) {
        uint256 contractIndex = _getPositionsStorageContractIndex(positionId);
        return contractIndex >= nextPositionsStorageContractIndex
            ? address(0)
            : _getPositionsStorageContract(contractIndex);
    }

    function _createPositionsStorageContract(uint256 positionId) private {
        uint256 contractIndex = _getPositionsStorageContractIndex(positionId);
        if (contractIndex >= nextPositionsStorageContractIndex) {
            ++nextPositionsStorageContractIndex;
            Create2.deploy(
                0,
                bytes32(contractIndex),
                type(PangolinStakingPositionsStorage).creationCode
            );
        }
    }

    function positions(uint256 positionId) public view returns (Position memory) {
        uint256 contractIndex = _getPositionsStorageContractIndex(positionId);
        address positionsStorageContract = _getPositionsStorageContract(contractIndex);
        return PangolinStakingPositionsStorage(payable(positionsStorageContract)).positions(positionId);
    }

    function _setPosition(uint256 positionId, Position memory position) private {
        uint256 contractIndex = _getPositionsStorageContractIndex(positionId);
        address positionsStorageContract = _getPositionsStorageContract(contractIndex);
        PangolinStakingPositionsStorage(payable(positionsStorageContract)).updatePosition(positionId, position);
    }

    function _deletePosition(uint256 positionId) private {
        uint256 contractIndex = _getPositionsStorageContractIndex(positionId);
        address positionsStorageContract = _getPositionsStorageContract(contractIndex);
        PangolinStakingPositionsStorage(payable(positionsStorageContract)).deletePosition(positionId);
    }

    function _getPositionsStorageContractIndex(uint256 positionId) private pure returns (uint256) {
        return positionId / STORAGE_SIZE;
    }

    function _receiveRent(uint256 rentTime) private {
        int256 tmpRentInTinyBars = rentInTinyBars;
        uint256 totalRent = tmpRentInTinyBars < 0
            ? rentTime * tinycentsToTinybars(THREE_MONTHS_RENT) / THREE_MONTHS
            : rentTime * uint256(tmpRentInTinyBars) / THREE_MONTHS;
        if (msg.value < totalRent || msg.value > totalRent * 2) revert InvalidAmount(); // don't bother with refund. rent amount is minimal.
    }

    function _getPositionsStorageContract(uint256 contractIndex) private view returns (address) {
        return Create2.computeAddress(
            bytes32(contractIndex),
            keccak256(type(PangolinStakingPositionsStorage).creationCode)
        );
    }

    /**
     * @notice Private function to deposit tokens to an existing position.
     * @param amount The amount of tokens to deposit into the position.
     * @param positionId The identifier of the position to deposit the funds into.
     * @return rentTime The duration for calculating the amount of rent to be topped up.
     * @dev Specifications:
     *      - Deposit `amount` tokens to the position associated with `positionId`,
     *      - Make the staking duration of `amount` restart,
     *      - Claim accrued `reward` tokens of the position,
     *      - Deposit `reward` tokens back into the position,
     *      - Make the staking duration of `reward` tokens start from zero.
     *      - Do not make the staking duration of the existing `balance` restart,
     */
    function _stake(uint256 positionId, uint256 amount) private onlyOwner(positionId) returns (uint256 rentTime) {
        // Create a storage pointer for the position.
        Position memory position = positions(positionId);

        // Get rewards accrued in the position.
        uint256 reward = _positionPendingRewards(position);

        // Include reward amount in total amount to be staked.
        uint256 totalAmount = amount + reward;
        if (totalAmount == 0) revert NoEffect();

        // Get the new total staked amount and ensure it fits 96 bits.
        uint256 newTotalStaked = totalValueVariables.balance + totalAmount;
        if (newTotalStaked > type(uint96).max) revert Overflow();

        unchecked {
            // The duration for calculating the amount of rent to be topped up.
            rentTime = block.timestamp - position.lastUpdate;

            // Increment the state variables pertaining to total value calculation.
            uint160 addedEntryTimes = uint160(block.timestamp * totalAmount);
            totalValueVariables.sumOfEntryTimes += addedEntryTimes;
            totalValueVariables.balance = uint96(newTotalStaked);

            // Increment the position properties pertaining to position value calculation.
            ValueVariables memory positionValueVariables = position.valueVariables;
            uint256 oldBalance = positionValueVariables.balance;
            positionValueVariables.balance = uint96(oldBalance + totalAmount);
            positionValueVariables.sumOfEntryTimes += addedEntryTimes;

            // Increment the previousValues.
            position.previousValues += uint160(oldBalance * rentTime);
        }

        // Snapshot the lastUpdate and summations.
        _snapshotRewardSummations(position);
        _setPosition(positionId, position);

        // Transfer amount tokens from user to the contract, and emit the associated event.
        if (amount != 0) _transferFromCaller(amount);
        emit Staked(positionId, amount, reward);
    }

    /**
     * @notice Private function to withdraw given amount of staked balance, plus all the accrued
     *         rewards from the position. Also acts as harvest when input amount is zero.
     * @param positionId The identifier of the position to withdraw the balance.
     * @param amount The amount of staked tokens, excluding rewards, to withdraw from the position.
     * @return rentTime The duration for calculating the amount of rent to be topped up.
     * @dev Specifications:
     *      - Claim accrued `reward` tokens of the position,
     *      - Send `reward` tokens from the contract to the position owner,
     *      - Send `amount` tokens from the contract to the position owner,
     *      - Make the staking duration of the remaining `balance` restart,
     */
    function _withdraw(uint256 positionId, uint256 amount) private onlyOwner(positionId) returns (uint256 rentTime) {
        // Create a storage pointer for the position.
        Position memory position = positions(positionId);

        // Get position balance and ensure sufficient balance exists.
        uint256 oldBalance = position.valueVariables.balance;
        if (amount > oldBalance) revert InsufficientBalance();

        // Get accrued rewards of the position and get totalAmount to withdraw (incl. rewards).
        uint256 reward = _positionPendingRewards(position);
        uint256 totalAmount = amount + reward;
        if (totalAmount == 0) revert NoEffect();

        unchecked {
            // The duration for calculating the amount of rent to be topped up.
            rentTime = block.timestamp - position.lastUpdate;

            // Get the remaining balance in the position.
            uint256 remaining = oldBalance - amount;

            // Decrement the withdrawn amount from totalStaked.
            totalValueVariables.balance -= uint96(amount);

            // Update sumOfEntryTimes.
            uint256 newEntryTimes = block.timestamp * remaining;
            ValueVariables memory positionValueVariables = position.valueVariables;
            totalValueVariables.sumOfEntryTimes = uint160(
                totalValueVariables.sumOfEntryTimes +
                    newEntryTimes -
                    positionValueVariables.sumOfEntryTimes
            );

            // Decrement the withdrawn amount from position balance and update position entryTimes.
            positionValueVariables.balance = uint96(remaining);
            positionValueVariables.sumOfEntryTimes = uint160(newEntryTimes);
        }

        // Reset the previous values, as we have restarted the staking duration.
        position.previousValues = 0;

        // Update lastDevaluation, as resetting the staking duration devalues the position.
        position.lastDevaluation = uint48(block.timestamp);

        // Snapshot the lastUpdate and summations.
        _snapshotRewardSummations(position);
        _setPosition(positionId, position);

        // Transfer withdrawn amount and rewards to the user, and emit the associated event.
        _transferToCaller(totalAmount);
        emit Withdrawn(positionId, amount, reward);
    }

    /**
     * @notice External function to exit from a position by forgoing rewards.
     * @param positionId The identifier of the position to exit from.
     * @dev Specifications:
     *      - Burn the NFT associated with `positionId`,
     *      - Close the position associated with `positionId`,
     *      - Send `balance` tokens of the position to the user wallet,
     *      - Ignore `reward` tokens, making them permanently irrecoverable.
     */
    function _emergencyExit(uint256 positionId) private onlyOwner(positionId) {
        // Move the queried position to memory.
        ValueVariables memory positionValueVariables = positions(positionId).valueVariables;

        // Decrement the state variables pertaining to total value calculation.
        uint96 balance = positionValueVariables.balance;
        unchecked {
            totalValueVariables.balance -= balance;
            totalValueVariables.sumOfEntryTimes -= positionValueVariables.sumOfEntryTimes;
        }

        // Simply destroy the position.
        _burn(positionId);

        // Transfer only the staked balance from the contract to user.
        _transferToCaller(balance);
        emit Withdrawn(positionId, balance, 0);
    }

    /**
     * @notice Private function to claim the total pending rewards, and based on the claimed amount
     *         update the two variables that govern the reward distribution.
     */
    function _updateRewardSummations() private {
        // Get rewards, in the process updating the last update time.
        uint256 rewards = _claim();

        // Get incrementations based on the reward amount.
        (
            uint256 idealPositionIncrementation,
            uint256 rewardPerValueIncrementation
        ) = _getRewardSummationsIncrementations(rewards);

        // Increment the summations.
        rewardSummationsStored.idealPosition += idealPositionIncrementation;
        rewardSummationsStored.rewardPerValue += rewardPerValueIncrementation;
    }

    /**
     * @notice Private function to snapshot two rewards variables and record the timestamp.
     * @param position The storage pointer to the position to record the snapshot for.
     */
    function _snapshotRewardSummations(Position memory position) private view {
        position.lastUpdate = uint48(block.timestamp);
        position.rewardSummationsPaid = rewardSummationsStored;
    }

    /**
     * @notice Private view function to get the accrued rewards of a position.
     * @dev The call to this function must only be made after the summations are updated
     *      through `_updateRewardSummations()`.
     * @param position The properties of the position.
     * @return The accrued rewards of the position.
     */
    function _positionPendingRewards(Position memory position) private view returns (uint256) {
        // Get the change in summations since the position was last updated. When calculating
        // the delta, do not increment `rewardSummationsStored`, as they had to be updated anyways.
        RewardSummations memory deltaRewardSummations = _getDeltaRewardSummations(position, false);

        // Return the pending rewards of the position.
        return _earned(deltaRewardSummations, position);
    }

    /**
     * @notice Private view function to get the difference between a position’s summations
     *         (‘paid’) and global summations (‘stored’).
     * @param position The position for which to calculate the delta of summations.
     * @param increment Whether to the incremented `rewardSummationsStored` based on the pending
     *                  rewards of the contract.
     * @return The difference between the `rewardSummationsStored` and `rewardSummationsPaid`.
     */
    function _getDeltaRewardSummations(Position memory position, bool increment)
        private
        view
        returns (RewardSummations memory)
    {
        // If position had no update to its summations yet, return zero.
        if (position.lastUpdate == 0) return RewardSummations(0, 0);

        // Create storage pointer to the position’s summations.
        RewardSummations memory rewardSummationsPaid = position.rewardSummationsPaid;

        // If requested, return the incremented `rewardSummationsStored`.
        if (increment) {
            // Get pending rewards, without updating the `lastUpdate`.
            uint256 rewards = _pendingRewards();

            // Get incrementations based on the reward amount.
            (
                uint256 idealPositionIncrementation,
                uint256 rewardPerValueIncrementation
            ) = _getRewardSummationsIncrementations(rewards);

            // Increment and return the incremented the summations.
            return
                RewardSummations(
                    rewardSummationsStored.idealPosition +
                        idealPositionIncrementation -
                        rewardSummationsPaid.idealPosition,
                    rewardSummationsStored.rewardPerValue +
                        rewardPerValueIncrementation -
                        rewardSummationsPaid.rewardPerValue
                );
        }

        // Otherwise just return the the delta, ignoring any incrementation from pending rewards.
        return
            RewardSummations(
                rewardSummationsStored.idealPosition - rewardSummationsPaid.idealPosition,
                rewardSummationsStored.rewardPerValue - rewardSummationsPaid.rewardPerValue
            );
    }

    /**
     * @notice Private view function to calculate the `rewardSummationsStored` incrementations
     *         based on the given reward amount.
     * @param rewards The amount of rewards to use for calculating the incrementation.
     * @return idealPositionIncrementation The incrementation to make to the idealPosition.
     * @return rewardPerValueIncrementation The incrementation to make to the rewardPerValue.
     */
    function _getRewardSummationsIncrementations(uint256 rewards)
        private
        view
        returns (uint256 idealPositionIncrementation, uint256 rewardPerValueIncrementation)
    {
        // Calculate the totalValue, then get the incrementations only if value is non-zero.
        uint256 totalValue = _getValue(totalValueVariables);
        if (totalValue != 0) {
            idealPositionIncrementation = (rewards * block.timestamp * PRECISION) / totalValue;
            rewardPerValueIncrementation = (rewards * PRECISION) / totalValue;
        }
    }

    /**
     * @notice Private view function to get the position or contract value.
     * @dev Value refers to the sum of each `wei` of tokens’ staking durations. So if there are
     *      10 tokens staked in the contract, and each one of them has been staked for 10 seconds,
     *      then the value is 100 (`10 * 10`). To calculate value we use sumOfEntryTimes, which is
     *      the sum of each `wei` of tokens’ staking-duration-starting timestamp. The formula
     *      below is intuitive and simple to derive. We will leave proving it to the reader.
     * @return The total value of contract or a position.
     */
    function _getValue(ValueVariables memory valueVariables) private view returns (uint256) {
        return block.timestamp * valueVariables.balance - valueVariables.sumOfEntryTimes;
    }

    /**
     * @notice Low-level private view function to get the accrued rewards of a position.
     * @param deltaRewardSummations The difference between the ‘stored’ and ‘paid’ summations.
     * @param position The position to check the accrued rewards of.
     * @return The accrued rewards of the position.
     */
    function _earned(RewardSummations memory deltaRewardSummations, Position memory position)
        private
        pure
        returns (uint256)
    {
        // Refer to the Combined Position section of the Proofs on why and how this formula works.
        return
            position.lastUpdate == 0
                ? 0
                : (((deltaRewardSummations.idealPosition -
                    (deltaRewardSummations.rewardPerValue * position.lastUpdate)) *
                    position.valueVariables.balance) +
                    (deltaRewardSummations.rewardPerValue * position.previousValues)) / PRECISION;
    }

    /* *********************** */
    /* OVERRIDES and NFT STUFF */
    /* *********************** */

    //function tokensOfOwnerByIndex(
    //    address owner,
    //    uint256 from,
    //    uint256 to
    //) external view returns (uint256[] memory) {
    //    if (from > to) revert OutOfBounds();

    //    uint256 length = to - from + 1;
    //    uint256[] memory tokens = new uint256[](length);
    //    while (from <= to) {
    //        tokens[from] = tokenOfOwnerByIndex(owner, from);
    //        unchecked {
    //            ++from;
    //        }
    //    }
    //    return tokens;
    //}

    function _burn(uint256 tokenId) private {
        // Delete position when burning the NFT.
        _deletePosition(tokenId);

        // Burn the token using HTS.
        int64[] memory tokenIds;
        tokenIds[0] = int64(int256(tokenId));
        int256 responseCode = wipeTokenAccountNFT(address(positionsToken), msg.sender, tokenIds);
        if (responseCode != HederaResponseCodes.SUCCESS) revert InvalidType();
    }

    function _mint() private returns (uint256 tokenId) {
        // Mint the token using HTS.
        (int256 mintResponseCode,,int64[] memory serialNumbers) =
            mintToken(address(positionsToken), 0, new bytes[](1));
        if (mintResponseCode != HederaResponseCodes.SUCCESS) revert InvalidType();
        tokenId = uint256(int256(serialNumbers[0]));

        // Transfer the token using HTS.
        address[] memory froms = new address[](1);
        froms[0] = address(this);
        address[] memory tos = new address[](1);
        tos[0] = msg.sender;
        int256 transferResponseCode =
            transferNFTs(address(positionsToken), froms, tos, serialNumbers);
        if (transferResponseCode != HederaResponseCodes.SUCCESS) revert InvalidType();
    }

    receive() external payable {}
}
