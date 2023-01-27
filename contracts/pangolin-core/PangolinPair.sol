// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;
pragma experimental ABIEncoderV2;

import './interfaces/IPangolinPair.sol';
import './libraries/Math.sol';
import './libraries/SafeMath.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IPangolinFactory.sol';
import './interfaces/IPangolinCallee.sol';

import '../hts-precompile/HederaResponseCodes.sol';
import '../hts-precompile/HederaTokenService.sol';
import "../hts-precompile/ExpiryHelper.sol";

contract PangolinPair is IPangolinPair, HederaTokenService, ExpiryHelper {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint private constant SUPPLY_KEY = 16; // 4th bit (counting from 0) flipped, i.e. 10000 binary.
    uint private constant MAXIMUM_HEDERA_TOKEN_SUPPLY = 2**63 - 1;
    uint public constant override MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public immutable override factory;
    address public override token0;
    address public override token1;
    address public override coreFeeCollector;

    address public override pairToken;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public override price0CumulativeLast;
    uint public override price1CumulativeLast;
    uint public override kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'Pangolin: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view override returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'Pangolin: TRANSFER_FAILED');
    }

    constructor() public {
        factory = msg.sender;
        coreFeeCollector = IPangolinFactory(msg.sender).coreFeeCollector();
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external payable override returns (address) {
        require(msg.sender == factory, 'Pangolin: FORBIDDEN'); // sufficient check

        address[] memory tokens = new address[](2);
        tokens[0] = _token0;
        tokens[1] = _token1;
        int associateResponseCode = HederaTokenService.associateTokens(address(this), tokens);
        require(associateResponseCode == HederaResponseCodes.SUCCESS, 'Pangolin: INVALID_TOKEN');

        token0 = _token0;
        token1 = _token1;

        // Create pair token. //
        ////////////////////////

        // Define the key of this contract.
        IHederaTokenService.KeyValue memory pairContractKey;
        pairContractKey.contractId = address(this);

        // Define a supply key which gives this contract minting and burning access.
        IHederaTokenService.TokenKey memory supplyKey;
        supplyKey.keyType = SUPPLY_KEY;
        supplyKey.key = pairContractKey;

        // Define the key types used in the token. Only supply key used.
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0] = supplyKey;

        // Define the token properties.
        IHederaTokenService.HederaToken memory token;
        token.name = "Pangolin Liquidity";
        token.symbol = "PGL";
        token.treasury = address(this); // also associates token?
        token.tokenKeys = keys;
        token.expiry = ExpiryHelper.createAutoRenewExpiry(address(this), 90 days);

        // Create the token, with zero initial supply, and zero decimals.
        (int256 tokenCreateResponseCode, address tokenId) = HederaTokenService.createFungibleToken(token, 0, uint32(0));
        require(tokenCreateResponseCode == HederaResponseCodes.SUCCESS, "Token creation failed");

        // Set the immutable state variables for the pair token.
        pairToken = tokenId;

        return tokenId;
    }

    function _mint(address to, uint amount) private {
        assert(amount <= MAXIMUM_HEDERA_TOKEN_SUPPLY);
        (int256 mintResponseCode,,) = HederaTokenService.mintToken(pairToken, uint64(amount), new bytes[](0));
        require(mintResponseCode == HederaResponseCodes.SUCCESS, "Mint failed");
        int256 transferResponseCode = HederaTokenService.transferToken(pairToken, address(this), to, int64(uint64(amount)));
        require(transferResponseCode == HederaResponseCodes.SUCCESS, "Transfer failed");
        emit LogicalMint(to, amount);
    }

    function _burn(address from, uint amount) private {
        assert(from == address(this));
        assert(amount <= MAXIMUM_HEDERA_TOKEN_SUPPLY);
        (int256 burnResponseCode,) = HederaTokenService.burnToken(pairToken, uint64(amount), new int64[](0));
        require(burnResponseCode == HederaResponseCodes.SUCCESS, "Burn failed");
        emit LogicalBurn(from, amount);
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'Pangolin: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IPangolinFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = IERC20(pairToken).totalSupply().mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(coreFeeCollector, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external override lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = IERC20(pairToken).totalSupply(); // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(factory, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'Pangolin: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external override lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = IERC20(pairToken).balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = IERC20(pairToken).totalSupply(); // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'Pangolin: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external override lock {
        require(amount0Out > 0 || amount1Out > 0, 'Pangolin: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'Pangolin: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'Pangolin: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IPangolinCallee(to).pangolinCall(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'Pangolin: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'Pangolin: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external override lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external override lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    receive() external payable {}
}
