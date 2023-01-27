// SPDX-License-Identifier: GPLv3
pragma solidity 0.8.15;

import "../hts-precompile/HederaResponseCodes.sol";
import "../hts-precompile/HederaTokenService.sol";

interface IPangoChef {
    function claim(uint256 poolId) external returns (uint256 reward);
    function rewardsToken() external view returns (address);
}

interface IPangolinStakingPositions {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function addReward(uint256 amount) external;
    function rewardsToken() external view returns (address);
}

contract EmissionDiversionFromPangoChefToPangolinStakingPositions is HederaTokenService {
    IPangoChef public immutable pangoChef;
    IPangolinStakingPositions public immutable pangolinStakingPositions;
    address public immutable rewardsToken;
    uint256 private immutable REWARDS_TOKEN_MAX_SUPPLY;
    bytes32 private constant FUNDER_ROLE = keccak256("FUNDER_ROLE");


    modifier onlyFunder() {
        require(pangolinStakingPositions.hasRole(FUNDER_ROLE, msg.sender), "unauthorized");
        _;
    }

    constructor(address newPangoChef, address newStakingPositions) {
        require(newPangoChef.code.length != 0, "empty contract");
        address newRewardsToken = IPangoChef(newPangoChef).rewardsToken();
        require(
            newRewardsToken == IPangolinStakingPositions(newStakingPositions).rewardsToken(),
            "invalid addresses"
        );

        (int responseCode, IHederaTokenService.FungibleTokenInfo memory tokenInfo) = HederaTokenService.getFungibleTokenInfo(newRewardsToken);
        require(responseCode == HederaResponseCodes.SUCCESS, "Token info request failed");

        responseCode = HederaTokenService.associateToken(address(this), newRewardsToken);
        require(responseCode == HederaResponseCodes.SUCCESS, "Association failed");

        pangoChef = IPangoChef(newPangoChef);
        pangolinStakingPositions = IPangolinStakingPositions(newStakingPositions);
        rewardsToken = newRewardsToken;
        REWARDS_TOKEN_MAX_SUPPLY = uint256(uint64(tokenInfo.tokenInfo.token.maxSupply));
    }

    function approve() external {
        int responseCode = HederaTokenService.approve(address(rewardsToken), address(pangolinStakingPositions), REWARDS_TOKEN_MAX_SUPPLY);
        require(responseCode == HederaResponseCodes.SUCCESS, "Approval failed");
    }

    function claimAndAddReward(uint256 poolId) external onlyFunder {
        uint256 amount = pangoChef.claim(poolId);
        pangolinStakingPositions.addReward(amount);
    }

    function notifyRewardAmount(uint256 amount) external onlyFunder {
        pangolinStakingPositions.addReward(amount);
    }
}
