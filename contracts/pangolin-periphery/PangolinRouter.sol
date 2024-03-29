// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import '../hts-precompile/HederaResponseCodes.sol';
import '../hts-precompile/HederaTokenService.sol';

import '../pangolin-core/interfaces/IPangolinFactory.sol';
import '../pangolin-lib/libraries/TransferHelper.sol';

import './interfaces/IPangolinRouter.sol';
import './libraries/PangolinLibrary.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWAVAX.sol';

contract PangolinRouter is IPangolinRouter, HederaTokenService {
    using SafeMath for uint;

    address public immutable override factory;
    IWAVAX public immutable override wavaxContract;
    address public immutable override wavaxToken;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'PangolinRouter: EXPIRED');
        _;
    }

    constructor(address _factory, address _wavaxContract) public {
        factory = _factory;
        wavaxContract = IWAVAX(_wavaxContract);
        address tmpWavaxToken = IWAVAX(_wavaxContract).TOKEN_ID();
        wavaxToken = tmpWavaxToken;

        // Associate Hedera native token to this address (i.e.: allow this contract to hold the token).
        int responseCode = HederaTokenService.associateToken(address(this), tmpWavaxToken);
        require(responseCode == HederaResponseCodes.SUCCESS, 'Association failed');
    }

    receive() external payable {}

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual view returns (uint amountA, uint amountB) {
        (uint reserveA, uint reserveB) = PangolinLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = PangolinLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'PangolinRouter: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = PangolinLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'PangolinRouter: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pairContract = PangolinLibrary.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pairContract, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pairContract, amountB);
        liquidity = IPangolinPair(pairContract).mint(to);
    }
    function addLiquidityAVAX(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountAVAXMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountAVAX, uint liquidity) {
        (amountToken, amountAVAX) = _addLiquidity(
            token,
            wavaxToken,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountAVAXMin
        );
        address pairContract = PangolinLibrary.pairFor(factory, token, wavaxToken);
        TransferHelper.safeTransferFrom(token, msg.sender, pairContract, amountToken);
        wavaxContract.deposit{value: amountAVAX}();
        TransferHelper.safeTransfer(wavaxToken, pairContract, amountAVAX);
        liquidity = IPangolinPair(pairContract).mint(to);
        // refund dust AVAX, if any
        if (msg.value > amountAVAX) TransferHelper.safeTransferAVAX(msg.sender, msg.value - amountAVAX);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        address pairContract = PangolinLibrary.pairFor(factory, tokenA, tokenB);
        address pairToken = IPangolinPair(pairContract).pairToken();
        IERC20(pairToken).transferFrom(msg.sender, pairContract, liquidity); // send liquidity to pair
        (uint amount0, uint amount1) = IPangolinPair(pairContract).burn(to);
        (address token0,) = PangolinLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'PangolinRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'PangolinRouter: INSUFFICIENT_B_AMOUNT');
    }
    function removeLiquidityAVAX(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountAVAXMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountAVAX) {
        _associateToken(token);

        (amountToken, amountAVAX) = removeLiquidity(
            token,
            wavaxToken,
            liquidity,
            amountTokenMin,
            amountAVAXMin,
            address(this),
            deadline
        );

        TransferHelper.safeTransfer(token, to, amountToken);

        // token cannot be WAVAX or tx would revert above with a WAVAX/WAVAX pair
        _disassociateToken(token);

        wavaxContract.withdraw(amountAVAX);
        TransferHelper.safeTransferAVAX(to, amountAVAX);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityAVAXSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountAVAXMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountAVAX) {
        _associateToken(token);

        (, amountAVAX) = removeLiquidity(
            token,
            wavaxToken,
            liquidity,
            amountTokenMin,
            amountAVAXMin,
            address(this),
            deadline
        );

        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));

        // token cannot be WAVAX or tx would revert above with a WAVAX/WAVAX pair
        _disassociateToken(token);

        wavaxContract.withdraw(amountAVAX);
        TransferHelper.safeTransferAVAX(to, amountAVAX);
    }

    function _associateToken(address _token) internal {
        int256 responseCode = HederaTokenService.associateToken(address(this), _token);
        require(responseCode == HederaResponseCodes.SUCCESS, 'Association failed');
    }

    function _disassociateToken(address _token) internal {
        int256 responseCode = HederaTokenService.dissociateToken(address(this), _token);
        require(responseCode == HederaResponseCodes.SUCCESS, 'Disassociation failed');
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = PangolinLibrary.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? PangolinLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IPangolinPair(PangolinLibrary.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = PangolinLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'PangolinRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, PangolinLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = PangolinLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'PangolinRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, PangolinLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapExactAVAXForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == wavaxToken, 'PangolinRouter: INVALID_PATH');
        amounts = PangolinLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'PangolinRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        wavaxContract.deposit{value: amounts[0]}();
        TransferHelper.safeTransfer(wavaxToken, PangolinLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }
    function swapTokensForExactAVAX(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == wavaxToken, 'PangolinRouter: INVALID_PATH');
        amounts = PangolinLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'PangolinRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, PangolinLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        wavaxContract.withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferAVAX(to, amounts[amounts.length - 1]);
    }
    function swapExactTokensForAVAX(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == wavaxToken, 'PangolinRouter: INVALID_PATH');
        amounts = PangolinLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'PangolinRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, PangolinLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        wavaxContract.withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferAVAX(to, amounts[amounts.length - 1]);
    }
    function swapAVAXForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == wavaxToken, 'PangolinRouter: INVALID_PATH');
        amounts = PangolinLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'PangolinRouter: EXCESSIVE_INPUT_AMOUNT');
        wavaxContract.deposit{value: amounts[0]}();
        TransferHelper.safeTransfer(wavaxToken, PangolinLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        // refund dust AVAX, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferAVAX(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = PangolinLibrary.sortTokens(input, output);
            IPangolinPair pairContract = IPangolinPair(PangolinLibrary.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pairContract.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pairContract)).sub(reserveInput);
            amountOutput = PangolinLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? PangolinLibrary.pairFor(factory, output, path[i + 2]) : _to;
            pairContract.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, PangolinLibrary.pairFor(factory, path[0], path[1]), amountIn
        );
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'PangolinRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactAVAXForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == wavaxToken, 'PangolinRouter: INVALID_PATH');
        uint amountIn = msg.value;
        wavaxContract.deposit{value: amountIn}();
        TransferHelper.safeTransfer(wavaxToken, PangolinLibrary.pairFor(factory, path[0], path[1]), amountIn);
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'PangolinRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactTokensForAVAXSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == wavaxToken, 'PangolinRouter: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, PangolinLibrary.pairFor(factory, path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint amountOut = IERC20(wavaxToken).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'PangolinRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        wavaxContract.withdraw(amountOut);
        TransferHelper.safeTransferAVAX(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return PangolinLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return PangolinLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return PangolinLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return PangolinLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return PangolinLibrary.getAmountsIn(factory, amountOut, path);
    }
}
