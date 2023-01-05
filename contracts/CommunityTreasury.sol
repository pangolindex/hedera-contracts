pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./hts-precompile/HederaResponseCodes.sol";
import "./hts-precompile/HederaTokenService.sol";

contract CommunityTreasury is HederaTokenService, Ownable {
    address public immutable TOKEN;

    constructor(address token) {
        int256 responseCode = HederaTokenService.associateToken(address(this), token);
        require(responseCode == HederaResponseCodes.SUCCESS, "Association failed");

        TOKEN = token;
    }

    function transfer(address to, int64 amount) external onlyOwner {
        int256 responseCode = HederaTokenService.transferToken(TOKEN, address(this), to, amount);
        require(responseCode == HederaResponseCodes.SUCCESS, "Transfer failed");
    }

    function balance() view external returns(uint256) {
        return IERC20(TOKEN).balanceOf(address(this));
    }
}