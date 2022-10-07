// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;
pragma experimental ABIEncoderV2;

import '../hts-precompile/HederaResponseCodes.sol';
import '../hts-precompile/HederaTokenService.sol';

import './interfaces/ILogicalBurn.sol';

contract LogicalBurn is ILogicalBurn, HederaTokenService {
    address public immutable override factory;

    event Associated(address indexed token);

    constructor() public {
        factory = msg.sender;
    }

    // called by the factory when new pairs are created
    function associate(address token) external override {
        require(msg.sender == factory, 'Pangolin: FORBIDDEN'); // sufficient check

        // Associate Hedera native token to this address (i.e.: allow this contract to hold the token).
        int responseCode = associateToken(address(this), token);
        require(responseCode == HederaResponseCodes.SUCCESS, 'Assocation failed');

        emit Associated(token);
    }
}
