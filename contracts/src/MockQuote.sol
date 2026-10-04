// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @title MockQuote
/// @notice Rehearsal-only stand-in for the quote asset in the OMNI buyback
///         pool (RUB-pegged stablecoin / USDT analogue). Mintable by anyone —
///         must never ship to production; production uses a real settlement
///         asset chosen with the business side.
contract MockQuote is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
