// SPDX-License-Identifier: MIT
pragma solidity =0.5.16;

import './interfaces/IPangolinFactory.sol';
import './PangolinPair.sol';

contract PangolinFactory is IPangolinFactory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) private _pairs;

    event PairCreated(address indexed token0, address indexed token1, address pair);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return tokenA < tokenB ? _pairs[tokenA][tokenB] : _pairs[tokenB][tokenA];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'Pangolin: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Pangolin: ZERO_ADDRESS');
        require(_pairs[token0][token1] == address(0), 'Pangolin: PAIR_EXISTS');
        bytes memory bytecode = type(PangolinPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IPangolinPair(pair).initialize(token0, token1);
        _pairs[token0][token1] = pair;
        emit PairCreated(token0, token1, pair);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'Pangolin: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'Pangolin: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
