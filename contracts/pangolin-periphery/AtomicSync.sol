// SPDX-License-Identifier: MIT
pragma solidity =0.8.15;

import '../hts-precompile/HederaResponseCodes.sol';
import '../hts-precompile/HederaTokenService.sol';

import '../pangolin-core/interfaces/IPangolinPair.sol';

// @dev Atomically top up a Pair contract and sync the new balances into reserves
contract AtomicSync is HederaTokenService {

    receive() external payable {}

    // @dev Caller must approve AtomicSync to spend token0 and token1
    // @dev No association is required
    function sync(address pair, address tokenA, int64 amountA, address tokenB, int64 amountB) external {
        address token0 = IPangolinPair(pair).token0();
        address token1 = IPangolinPair(pair).token1();

        require(
            (token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA),
            "Invalid tokens"
        );

        _transferFrom(tokenA, pair, amountA);
        _transferFrom(tokenB, pair, amountB);

        IPangolinPair(pair).sync();
    }

    function _transferFrom(address token, address to, int64 amount) internal {
        int256 responseCode = HederaTokenService.transferToken(token, msg.sender, to, amount);
        require(responseCode == HederaResponseCodes.SUCCESS, "Transfer failed");
    }
}
