// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { OMNIBurner } from "./OMNIBurner.sol";

/// @title FeeSplitter
/// @notice Immutable 70/30 split of collected protocol fees (native OMNI).
///         Fee-vault withdrawals land on this contract; anyone may call
///         `sweep()` — 70% is provably burned via OMNIBurner (dead address),
///         30% goes to the OMNICORTreasury contract. The ratio is a
///         hardcoded constant: no owner, no setter, no upgrade path.
contract FeeSplitter {
    uint256 public constant BPS = 10_000;

    /// @notice Burn share of every sweep: 70% — decided platform policy.
    uint256 public constant BURN_BPS = 7_000;

    /// @notice Burn sink that forwards OMNI to 0x...dEaD and counts it.
    OMNIBurner public immutable BURNER;

    /// @notice OMNICORTreasury contract receiving the kept 30%.
    address public immutable TREASURY;

    /// @notice Cumulative OMNI burned through this splitter.
    uint256 public totalBurned;

    /// @notice Cumulative OMNI forwarded to the treasury.
    uint256 public totalToTreasury;

    event Split(address indexed caller, uint256 burned, uint256 toTreasury);

    error ZeroAddress();
    error NothingToSplit();
    error TreasurySendFailed();

    constructor(OMNIBurner burner_, address treasury_) {
        if (address(burner_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        BURNER = burner_;
        TREASURY = treasury_;
    }

    /// @notice Vault withdrawals and any other native OMNI land here.
    receive() external payable { }

    /// @notice Splits the entire balance: 70% burned, 30% to treasury.
    ///         Permissionless — destinations are immutable, so the caller
    ///         cannot redirect a single wei.
    function sweep() external {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToSplit();
        uint256 toBurn = (bal * BURN_BPS) / BPS;
        uint256 toKeep = bal - toBurn;
        totalBurned += toBurn;
        totalToTreasury += toKeep;
        emit Split(msg.sender, toBurn, toKeep);
        if (toBurn > 0) BURNER.burnDirect{ value: toBurn }();
        (bool ok,) = TREASURY.call{ value: toKeep }("");
        if (!ok) revert TreasurySendFailed();
    }
}
