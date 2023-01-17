// SPDX-License-Identifier: MIT
pragma solidity =0.8.15;

import "../hts-precompile/HederaResponseCodes.sol";
import "../hts-precompile/HederaTokenService.sol";

import "./interfaces/IRewarder.sol";

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
}

contract RewarderViaMultiplierForPangoChef is IRewarder, HederaTokenService {

    address[] public rewardTokens;
    uint256[] public rewardMultipliers;
    address private immutable PANGO_CHEF;
    uint256 private immutable BASE_REWARD_TOKEN_DIVISOR;

    // @dev Ceiling on additional rewards to prevent a self-inflicted DOS via gas limitations when claim
    uint256 private constant MAX_REWARDS = 100;

    /// @dev Additional reward quantities that might be owed to users trying to claim after funds have been exhausted
    mapping(address => mapping(uint256 => uint256)) private rewardDebts;

    /// @param _rewardTokens The address of each additional reward token
    /// @param _rewardMultipliers The amount of each additional reward token to be claimable for every 1 base reward (PNG) being claimed
    /// @param _baseRewardTokenDecimals The decimal precision of the base reward (PNG) being emitted
    /// @param _pangoChef The address of the chef contract where the base reward (PNG) is being emitted
    /// @notice Each reward multiplier should have a precision matching that individual token
    constructor (
        address[] memory _rewardTokens,
        uint256[] memory _rewardMultipliers,
        uint256 _baseRewardTokenDecimals,
        address _pangoChef
    ) {
        require(
            _rewardTokens.length > 0
            && _rewardTokens.length <= MAX_REWARDS
            && _rewardTokens.length == _rewardMultipliers.length,
            "Invalid input lengths"
        );

        require(
            _baseRewardTokenDecimals <= 77,
            "Invalid base reward decimals"
        );

        require(
            _pangoChef != address(0),
            "Invalid chef address"
        );

        for (uint256 i; i < _rewardTokens.length; ++i) {
            require(_rewardTokens[i] != address(0), "Cannot reward zero address");
            require(_rewardMultipliers[i] > 0, "Invalid multiplier");
        }

        int256 associateResponseCode = HederaTokenService.associateTokens(address(this), _rewardTokens);
        require(associateResponseCode == HederaResponseCodes.SUCCESS, "Association failed");

        rewardTokens = _rewardTokens;
        rewardMultipliers = _rewardMultipliers;
        BASE_REWARD_TOKEN_DIVISOR = 10 ** _baseRewardTokenDecimals;
        PANGO_CHEF = _pangoChef;
    }

    // @dev Allows funding auto-rent payments
    receive() external payable {}

    function onReward(
        uint256,
        address user,
        bool destructiveAction,
        uint256 rewardAmount,
        uint256
    ) onlyChef override external {
        uint256 tokensLength = rewardTokens.length;
        for (uint256 i; i < tokensLength; ++i) {
            uint256 pendingReward = rewardDebts[user][i] + (rewardAmount * rewardMultipliers[i] / BASE_REWARD_TOKEN_DIVISOR);
            uint256 rewardBal = IERC20(rewardTokens[i]).balanceOf(address(this));
            if (!destructiveAction) {
                rewardDebts[user][i] = pendingReward;
            } else if (pendingReward > rewardBal) {
                rewardDebts[user][i] = pendingReward - rewardBal;
                _transferReward(rewardTokens[i], user, rewardBal);
            } else {
                rewardDebts[user][i] = 0;
                _transferReward(rewardTokens[i], user, pendingReward);
            }
        }
    }

    /// @notice Shows pending tokens that can be currently claimed
    function pendingTokens(uint256, address user, uint256 rewardAmount) external view returns (address[] memory tokens, uint256[] memory amounts) {
        uint256 tokensLength = rewardTokens.length;
        amounts = new uint256[](tokensLength);
        for (uint256 i; i < tokensLength; ++i) {
            uint256 pendingReward = rewardDebts[user][i] + (rewardAmount * rewardMultipliers[i] / BASE_REWARD_TOKEN_DIVISOR);
            uint256 rewardBal = IERC20(rewardTokens[i]).balanceOf(address(this));
            if (pendingReward > rewardBal) {
                amounts[i] = rewardBal;
            } else {
                amounts[i] = pendingReward;
            }
        }
        return (rewardTokens, amounts);
    }

    /// @notice Shows pending tokens including rewards accrued after the funding has been exhausted
    /// @notice these extra rewards could be claimed if more funding is added to the contract
    function pendingTokensDebt(uint256, address user, uint256 rewardAmount) external view returns (address[] memory tokens, uint256[] memory amounts) {
        uint256 tokensLength = rewardTokens.length;
        amounts = new uint256[](tokensLength);
        for (uint256 i; i < tokensLength; ++i) {
            uint256 pendingReward = rewardDebts[user][i] + (rewardAmount * rewardMultipliers[i] / BASE_REWARD_TOKEN_DIVISOR);
            amounts[i] = pendingReward;
        }
        return (rewardTokens, amounts);
    }

    /// @notice Overloaded getter for easy access to the reward tokens
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /// @notice Overloaded getter for easy access to the reward multipliers
    function getRewardMultipliers() external view returns (uint256[] memory) {
        return rewardMultipliers;
    }

    function _transferReward(address reward, address recipient, uint256 amount) private {
        int256 transferResponseCode = HederaTokenService.transferToken(reward, address(this), recipient, int64(uint64(amount)));
        require(transferResponseCode == HederaResponseCodes.SUCCESS, "Transfer failed");
    }

    modifier onlyChef {
        require(msg.sender == PANGO_CHEF, "Only PangoChef");
        _;
    }

}
