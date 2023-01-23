// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import '../hts-precompile/HederaResponseCodes.sol';
import '../hts-precompile/HederaTokenService.sol';

import './interfaces/ICoreFeeCollector.sol';
import './interfaces/IPangolinFactory.sol';

contract CoreFeeCollector is ICoreFeeCollector, HederaTokenService {
    address public immutable override factory;

    constructor() public {
        factory = msg.sender;
    }

    function withdraw(address token, address to, uint256 amount) external override {
        require(msg.sender == feeTo(), 'Pangolin: UNAUTHORIZED');
        require(amount != 0, 'Pangolin: NO OP');
        require(amount <= uint256(uint64(type(int64).max)), 'Pangolin: OVERFLOW');

        int256 transferResponseCode = HederaTokenService.transferToken(token, address(this), to, int64(uint64(amount)));
        require(transferResponseCode == HederaResponseCodes.SUCCESS, 'Transfer failed');

        emit Withdrawn(token, to, amount);
    }

    // called by the factory when new pairs are created
    function associate(address token) external override {
        require(msg.sender == factory, 'Pangolin: FORBIDDEN'); // sufficient check

        int256 responseCode = HederaTokenService.associateToken(address(this), token);
        require(responseCode == HederaResponseCodes.SUCCESS, 'Association failed');

        emit Associated(token);
    }

    function feeTo() public view override returns (address) {
        return IPangolinFactory(factory).feeTo();
    }

    receive() external payable {}
}
