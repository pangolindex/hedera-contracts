// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import '../PangolinERC20.sol';

contract ERC20 is PangolinERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}
