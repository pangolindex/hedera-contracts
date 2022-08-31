// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import './interfaces/IContractSizeChecker.sol';
import './interfaces/IPangolinFactory.sol';
import './PangolinPair.sol';
import './LogicalBurn.sol';

contract PangolinFactory is IPangolinFactory {
    address public override feeTo;
    address public override feeToSetter;
    uint public override allPairsLength;
    uint private constant MAX_ASSOCIATIONS = 1000;
    address private immutable CONTRACT_SIZE_CHECKER;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    event BurnContractCreated(address indexed logicalBurnAddress, uint indexed index);

    constructor(address _feeToSetter, address _contractSizeChecker) public {
        feeToSetter = _feeToSetter;
        CONTRACT_SIZE_CHECKER = _contractSizeChecker;
    }

    // We have to use an external contract for this because in Hedera even low-level
    // calls made to non-contracts revert.
    function _contractExists(address contractAddress) private view returns (bool) {
        (bool success, bytes memory returndata) = CONTRACT_SIZE_CHECKER.staticcall{ gas: 100000 }(
            abi.encodeWithSelector(IContractSizeChecker.checkCodeSize.selector, contractAddress)
        );
        return (success && returndata.length > 0 && abi.decode(returndata, (uint256)) > 0);
    }

    function getPair(address tokenA, address tokenB) public view override returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pair = address(uint(keccak256(abi.encodePacked(
            hex'ff',
            address(this),
            keccak256(abi.encodePacked(token0, token1)),
            keccak256(type(PangolinPair).creationCode)
        ))));
        return _contractExists(pair) ? pair : address(0);
    }

    function getBurnContract(uint index) public view override returns (address) {
        uint length = allPairsLength;
        if (length == 0) {
            return address(0);
        } else {
            return ((length - 1) / MAX_ASSOCIATIONS >= index)
                ? _getBurnContract(index)
                : address(0);
        }
    }

    function _getBurnContract(uint index) private view returns (address) {
        return address(uint(keccak256(abi.encodePacked(
            hex'ff',
            address(this),
            index,
            keccak256(type(LogicalBurn).creationCode)
        ))));
    }

    function createPair(address tokenA, address tokenB) external payable override returns (address pair) {
        require(tokenA != tokenB, 'Pangolin: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Pangolin: ZERO_ADDRESS');
        require(getPair(token0, token1) == address(0), 'Pangolin: PAIR_EXISTS'); // single check is sufficient

        // Create the burn contract
        // contract that will work as logical burn for initial pair token mint. there has to be
        // a new burn contract deployed after a thousand, because thousand is the max token association.
        uint256 burnContractIndex = allPairsLength / MAX_ASSOCIATIONS;
        address burnContract;
        if (allPairsLength % MAX_ASSOCIATIONS == 0) {
            bytes memory burnContractBytecode = type(LogicalBurn).creationCode;
            assembly {
                burnContract := create2(0, add(burnContractBytecode, 32), mload(burnContractBytecode), burnContractIndex)
            }
            emit BurnContractCreated(burnContract, burnContractIndex);
        } else {
            burnContract = getBurnContract(burnContractIndex);
        }

        // Create the pair contract
        bytes memory pairBytecode = type(PangolinPair).creationCode;
        bytes32 pairSalt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(pairBytecode, 32), mload(pairBytecode), pairSalt)
        }
        address pairToken = IPangolinPair(pair).initialize{ value: msg.value }(token0, token1, burnContract);
        ILogicalBurn(burnContract).associate(pairToken); // Allow burn contract to hold the pair token.
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
