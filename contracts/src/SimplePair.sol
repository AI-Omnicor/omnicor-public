// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";

/// @title SimplePair
/// @notice Minimal constant-product (x*y=k) AMM pair, UniswapV2-compatible
///         interface subset. Sufficient for the OMNICOR buyback pool and for
///         rehearsing the fiat→stable→OMNI→burn flow. For production deploy a
///         canonical UniswapV2 fork (Pair+Factory) — this contract is the
///         rehearsal/reference implementation.
///
///         Swap fee: 0.3% retained in the pool (same as UniV2).
contract SimplePair {
    using SafeERC20 for IERC20;

    string public constant name = "OMNI LP";
    string public constant symbol = "OMNI-LP";
    uint8 public constant decimals = 18;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint112 public reserve0;
    uint112 public reserve1;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error Locked();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error InsufficientInput();
    error InvalidRecipient();
    error K();
    error ZeroAddress();
    error IdenticalTokens();
    error UnknownToken(address tokenIn);
    error Overflow();

    uint256 private _unlocked = 1;

    /// @dev UniV2-style reentrancy lock on state-changing pool functions.
    ///      Plain ERC-20s can't reenter, but the pair must stay safe if a
    ///      hook-bearing token (ERC-777-style) is ever paired.
    modifier lock() {
        if (_unlocked != 1) revert Locked();
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor(IERC20 _token0, IERC20 _token1) {
        if (address(_token0) == address(0) || address(_token1) == address(0)) revert ZeroAddress();
        if (_token0 == _token1) revert IdenticalTokens();
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    /// @notice Spot price of token0 denominated in token1, scaled 1e18.
    function price0() public view returns (uint256) {
        if (reserve0 == 0) return 0;
        return (uint256(reserve1) * 1e18) / uint256(reserve0);
    }

    /// @notice Spot price of token1 denominated in token0, scaled 1e18.
    function price1() public view returns (uint256) {
        if (reserve1 == 0) return 0;
        return (uint256(reserve0) * 1e18) / uint256(reserve1);
    }

    /// @notice Quote: how much of the other token comes out for `amountIn`
    ///         of `tokenIn`, including the 0.3% fee (UniswapV2 formula).
    ///         Reverts for tokens that are not part of this pair — silently
    ///         quoting against the wrong side produced misleading prices.
    function getAmountOut(uint256 amountIn, address tokenIn) public view returns (uint256 amountOut) {
        (uint112 r0, uint112 r1) = getReserves();
        uint256 rIn;
        uint256 rOut;
        if (tokenIn == address(token0)) {
            (rIn, rOut) = (uint256(r0), uint256(r1));
        } else if (tokenIn == address(token1)) {
            (rIn, rOut) = (uint256(r1), uint256(r0));
        } else {
            revert UnknownToken(tokenIn);
        }
        amountOut = getAmountOut(amountIn, rIn, rOut);
    }

    /// @notice Pure quote used by integrators for reserve-mode estimation:
    ///         UniswapV2 formula with 0.3% fee, no state reads.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "SimplePair: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "SimplePair: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= value;
        }
        _transfer(from, to, value);
        return true;
    }

    /// @notice Sync reserves to actual balances. Permissionless.
    function sync() public lock {
        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    /// @notice Recover tokens sent in excess of reserves to `to`.
    function skim(address to) public lock {
        token0.safeTransfer(to, token0.balanceOf(address(this)) - reserve0);
        token1.safeTransfer(to, token1.balanceOf(address(this)) - reserve1);
    }

    /// @notice Adds liquidity: transfer token0/token1 in first, then call mint.
    ///         LP tokens are minted to `to`. UniV2 liquidity math.
    function mint(address to) public lock returns (uint256 liquidity) {
        (uint112 _r0, uint112 _r1) = getReserves();
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        uint256 amount0 = bal0 - _r0;
        uint256 amount1 = bal1 - _r1;

        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY); // permanently locked
        } else {
            liquidity = Math.min((amount0 * _totalSupply) / _r0, (amount1 * _totalSupply) / _r1);
        }
        if (liquidity == 0) revert InsufficientLiquidity();
        _mint(to, liquidity);

        _update(bal0, bal1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Removes liquidity: transfer LP tokens in, then call burn.
    function burn(address to) public lock returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf[address(this)];
        uint256 _totalSupply = totalSupply;
        amount0 = (liquidity * token0.balanceOf(address(this))) / _totalSupply;
        amount1 = (liquidity * token1.balanceOf(address(this))) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidity();
        _burn(address(this), liquidity);
        token0.safeTransfer(to, amount0);
        token1.safeTransfer(to, amount1);
        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Swap: transfer the input token in, then call swap specifying
    ///         the desired output amounts (use getAmountOut for a quote).
    ///         Exactly one of amount0Out/amount1Out must be zero.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) public lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutput();
        (uint112 _r0, uint112 _r1) = getReserves();
        if (amount0Out >= _r0 || amount1Out >= _r1) revert InsufficientLiquidity();
        // UniV2 forbids paying out to either token address — the output
        // would be absorbed by the token contract, not the recipient.
        if (to == address(token0) || to == address(token1)) revert InvalidRecipient();

        if (amount0Out > 0) token0.safeTransfer(to, amount0Out);
        if (amount1Out > 0) token1.safeTransfer(to, amount1Out);

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        uint256 amount0In = bal0 > _r0 - amount0Out ? bal0 - (_r0 - amount0Out) : 0;
        uint256 amount1In = bal1 > _r1 - amount1Out ? bal1 - (_r1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInput();

        // k invariant with 0.3% fee on input
        uint256 bal0Adj = bal0 * 1000 - amount0In * 3;
        uint256 bal1Adj = bal1 * 1000 - amount1In * 3;
        if (bal0Adj * bal1Adj < uint256(_r0) * _r1 * 1e6) revert K();

        _update(bal0, bal1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @dev Store reserves with an explicit range check — a wider than
    ///      uint112 balance must revert instead of silently truncating.
    function _update(uint256 bal0, uint256 bal1) private {
        if (bal0 > type(uint112).max || bal1 > type(uint112).max) revert Overflow();
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
        emit Sync(reserve0, reserve1);
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
