// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../hts-precompile/HederaResponseCodes.sol";
import "../hts-precompile/HederaTokenService.sol";

interface IPangoChef {
    function rewardsToken() external view returns (address);

    function addReward(uint256 amount) external;

    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * @author shung for Pangolin
 * @author bmino for Pangolin
 * @notice
 *
 * Funder -> RewardFundingForwarder -> PangoChef
 *               OR
 * Funder -> RewardFundingForwarder -> PangolinStakingPositions
 *
 * Funder is any contract that was written for Synthetix' StakingRewards, or for MiniChef.
 * RewardFundingForwarder provides compatibility for these old funding contracts.
 */
contract RewardFundingForwarder is HederaTokenService {
    IPangoChef public immutable pangoChef;
    address public immutable rewardsToken;
    uint256 private immutable TOKEN_MAX_SUPPLY;
    bytes32 private constant FUNDER_ROLE = keccak256("FUNDER_ROLE");

    modifier onlyFunder() {
        require(pangoChef.hasRole(FUNDER_ROLE, msg.sender), "unauthorized");
        _;
    }

    constructor(address newPangoChef) {
        require(newPangoChef.code.length != 0, "empty contract");
        address newRewardsToken = IPangoChef(newPangoChef).rewardsToken();

        (int responseCode, IHederaTokenService.FungibleTokenInfo memory tokenInfo) = HederaTokenService.getFungibleTokenInfo(newRewardsToken);
        require(responseCode == HederaResponseCodes.SUCCESS, "Token info request failed");

        responseCode = HederaTokenService.associateToken(address(this), newRewardsToken);
        require(responseCode == HederaResponseCodes.SUCCESS, "Association failed");

        TOKEN_MAX_SUPPLY = uint256(uint64(tokenInfo.tokenInfo.token.maxSupply));
        pangoChef = IPangoChef(newPangoChef);
        rewardsToken = newRewardsToken;
    }

    function approve() external {
        int responseCode = HederaTokenService.approve(rewardsToken, address(pangoChef), TOKEN_MAX_SUPPLY);
        require(responseCode == HederaResponseCodes.SUCCESS, "Approval failed");
    }

    function notifyRewardAmount(uint256 amount) external onlyFunder {
        pangoChef.addReward(amount);
    }

    function fundRewards(uint256 amount, uint256) external {
        addReward(amount);
    }

    function addReward(uint256 amount) public onlyFunder {
        IERC20(rewardsToken).transferFrom(msg.sender, address(this), amount);
        pangoChef.addReward(amount);
    }
}
