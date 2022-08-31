// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface IContractSizeChecker {
    function checkCodeSize(address contractAddress) external view returns (uint size);
}
