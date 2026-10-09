// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical WETH interface for the router (WOMNI implements the same shape:
// deposit() / withdraw(uint) / approve / transfer / transferFrom).
pragma solidity >=0.8.0;

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
    function approve(address spender, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
}
