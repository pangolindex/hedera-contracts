// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import './hts-precompile/HederaResponseCodes.sol';
import './hts-precompile/HederaTokenService.sol';
import "./hts-precompile/ExpiryHelper.sol";

contract WHBAR is HederaTokenService, ExpiryHelper {
    string private constant NAME = "Wrapped Hedera";
    string private constant SYMBOL = "WHBAR";
    uint8 private constant DECIMALS = 8;
    uint private constant SUPPLY_KEY = 16;
    uint private constant MAXIMUM_HEDERA_TOKEN_SUPPLY = 2**63 - 1;

    address public immutable TOKEN_ID;

    event Deposit(address indexed dst, uint wad);
    event Withdrawal(address indexed src, uint wad);

    constructor() payable {
        // Define the key of this contract.
        IHederaTokenService.KeyValue memory key;
        key.contractId = address(this);

        // Define a supply key which gives this contract minting and burning access.
        IHederaTokenService.TokenKey memory supplyKey;
        supplyKey.keyType = SUPPLY_KEY;
        supplyKey.key = key;

        // Define the key types used in the token. Only supply key used.
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0] = supplyKey;

        // Define the token properties.
        IHederaTokenService.HederaToken memory token;
        token.name = NAME;
        token.symbol = SYMBOL;
        token.treasury = address(this); // also associates token.
        token.tokenKeys = keys;
        token.expiry = ExpiryHelper.createAutoRenewExpiry(address(this), 90 days);

        // Create the token.
        (int256 responseCode, address tokenId) = HederaTokenService.createFungibleToken(token, 0, uint32(DECIMALS));
        require(responseCode == HederaResponseCodes.SUCCESS, "Token creation failed");

        // Set the immutable state variable for the distribution token.
        TOKEN_ID = tokenId;
    }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        assert(msg.value <= MAXIMUM_HEDERA_TOKEN_SUPPLY);
        (int256 mintResponseCode,,) = HederaTokenService.mintToken(TOKEN_ID, uint64(msg.value), new bytes[](0));
        require(mintResponseCode == HederaResponseCodes.SUCCESS, "Mint failed");
        int256 transferResponseCode = HederaTokenService.transferToken(TOKEN_ID, address(this), msg.sender, int64(uint64(msg.value)));
        require(transferResponseCode == HederaResponseCodes.SUCCESS, "Transfer failed");
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint wad) external {
        assert(wad <= MAXIMUM_HEDERA_TOKEN_SUPPLY);
        int256 transferResponseCode = HederaTokenService.transferToken(TOKEN_ID, msg.sender, address(this), int64(uint64(wad)));
        require(transferResponseCode == HederaResponseCodes.SUCCESS, "Transfer failed");
        (int256 burnResponseCode,) = HederaTokenService.burnToken(TOKEN_ID, uint64(wad), new int64[](0));
        require(burnResponseCode == HederaResponseCodes.SUCCESS, "Burn failed");
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }
}
