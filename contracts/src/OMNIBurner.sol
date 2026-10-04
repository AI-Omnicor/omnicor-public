// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title OMNIBurner
/// @notice Verifiable burn sink for native OMNI on OMNICOR L2.
///         Funds arrive via plain transfers (fee-vault withdrawals, buyback
///         proceeds) and anyone can permissionlessly sweep them to the burn
///         address 0x...dEaD. Once at the dead address the native asset is
///         provably unrecoverable — equivalent to a supply reduction, since the
///         OMNI locked in the L1 bridge stays locked forever.
///
///         Burn accounting is fully on-chain and auditable:
///         - cumulative burned = balanceOf(0x...dEaD) attributable to this
///           contract can be tracked via the Burned event log;
///         - totalBurned() is kept as an explicit counter.
contract OMNIBurner {
    /// @notice Canonical burn address.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Total native OMNI this contract has sent to the burn address.
    uint256 public totalBurned;

    /// @notice Emitted whenever OMNI is swept to the burn address.
    event Burned(address indexed caller, uint256 amount, uint256 cumulative);

    /// @notice Accept native OMNI (vault withdrawals, buyback transfers).
    receive() external payable { }

    /// @notice Burn a specific amount held by this contract.
    function burn(uint256 amount) external {
        require(amount > 0 && amount <= address(this).balance, "OMNIBurner: bad amount");
        _send(amount);
    }

    /// @notice Sweep the entire contract balance to the burn address.
    function sweep() external {
        uint256 amount = address(this).balance;
        require(amount > 0, "OMNIBurner: nothing to burn");
        _send(amount);
    }

    /// @notice Burns native OMNI sent directly with the call.
    function burnDirect() external payable {
        require(msg.value > 0, "OMNIBurner: zero value");
        _send(msg.value);
    }

    function _send(uint256 amount) internal {
        totalBurned += amount;
        (bool ok,) = DEAD.call{ value: amount }("");
        require(ok, "OMNIBurner: burn failed");
        emit Burned(msg.sender, amount, totalBurned);
    }
}
