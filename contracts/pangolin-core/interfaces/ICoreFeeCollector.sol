// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface ICoreFeeCollector {
    event Associated(address indexed token);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    function factory() external view returns (address);
    function feeTo() external view returns (address);
    function associate(address token) external;
    function withdraw(address token, address to, uint256 amount) external;
}
