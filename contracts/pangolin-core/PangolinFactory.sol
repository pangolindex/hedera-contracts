// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import './interfaces/IPangolinFactory.sol';
import './PangolinPair.sol';

contract PangolinFactory is IPangolinFactory {
    address public override feeTo;
    address public override feeToSetter;
    uint public override allPairsLength;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function getPair(address tokenA, address tokenB) public view override returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pair = address(uint(keccak256(abi.encodePacked(
            hex'ff',
            address(this),
            keccak256(abi.encodePacked(token0, token1)),
            keccak256(type(PangolinPair).creationCode)
        ))));
        uint size;
        assembly {
            size := extcodesize(pair)
        }
        if (size > 0) return pair; else return address(0);
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, 'Pangolin: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Pangolin: ZERO_ADDRESS');
        require(getPair(token0, token1) == address(0), 'Pangolin: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(PangolinPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IPangolinPair(pair).initialize(token0, token1);
        ++allPairsLength;
        emit PairCreated(token0, token1, pair, allPairsLength);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, 'Pangolin: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, 'Pangolin: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
