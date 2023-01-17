// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface IWAVAX {
    function deposit() external payable;
    function deposit(address src, address dst) external payable;
    function transfer(address to, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function withdraw(uint) external;
    function withdraw(address src, address dst, uint) external;
    function TOKEN_ID() external view returns (address tokenId); // for WHBAR
}
