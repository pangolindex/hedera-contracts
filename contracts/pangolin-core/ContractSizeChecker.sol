// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import './interfaces/IContractSizeChecker.sol';

contract ContractSizeChecker is IContractSizeChecker {
    // On Hedera, if `contractAddress` does not exist, this function will revert. Therefore, any
    // external calls to this function must be done through a low-level call. If the revert is
    // detected, the calling function should assume the code size to be zero.
    function checkCodeSize(address contractAddress) external view override returns (uint size) {
        assembly {
            size := extcodesize(contractAddress)
        }
    }
}
