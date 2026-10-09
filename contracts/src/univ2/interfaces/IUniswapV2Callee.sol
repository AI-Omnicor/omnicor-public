// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical Uniswap V2 interface, ported to Solidity 0.8 (pragma only).
pragma solidity >=0.8.0;

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external;
}
