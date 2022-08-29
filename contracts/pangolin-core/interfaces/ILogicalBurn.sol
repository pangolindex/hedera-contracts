// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface ILogicalBurn {
    event Associated(address indexed token);
    function factory() external view returns (address);
    function associate(address token) external;
}
