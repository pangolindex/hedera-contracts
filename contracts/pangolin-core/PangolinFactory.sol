// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import './interfaces/IContractSizeChecker.sol';
import './interfaces/IPangolinFactory.sol';
import './PangolinPair.sol';
import './LogicalBurn.sol';

contract PangolinFactory is IPangolinFactory, HederaTokenService {
    address public override feeTo;
    address public override feeToSetter;
    uint public override allPairsLength;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function getPair(address tokenA, address tokenB) public view override returns (address pair) {
        address pairContract = getPairContract(tokenA, tokenB);
        if (pairContract != address(0)) pair = IPangolinPair(pairContract).pairToken();
    }

    function getPairContract(address tokenA, address tokenB) public view override returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(uint(keccak256(abi.encodePacked(
            hex'ff',
            address(this),
            keccak256(abi.encodePacked(token0, token1)),
            keccak256(type(PangolinPair).creationCode)
        ))));
        assembly {
            if iszero(extcodesize(pair)) { pair := 0 }
        }
    }

    function createPair(address tokenA, address tokenB) external payable override returns (address pair) {
        require(tokenA != tokenB, 'Pangolin: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Pangolin: ZERO_ADDRESS');
        bytes memory pairBytecode = type(PangolinPair).creationCode;
        bytes32 pairSalt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(pairBytecode, 32), mload(pairBytecode), pairSalt)
        }
        require(pair != address(0), 'Pangolin: PAIR_EXISTS');
        address pairToken = IPangolinPair(pair).initialize{ value: msg.value }(token0, token1);
        int associateResponseCode = associateToken(address(this), pairToken);
        require(associateResponseCode == HederaResponseCodes.SUCCESS, 'Pangolin: ASSOCATION_FAILED');
        emit PairCreated(token0, token1, pair, allPairsLength++);
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
