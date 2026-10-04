// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DevVesting
/// @notice Holds the 20% developer allocation of OMNICOR under a 6-month cliff
///         followed by linear vesting over 4 years from deploy time.
///
///         Before the cliff nothing is withdrawable. At the cliff, the vested
///         share accrued since deploy unlocks at once; afterwards the
///         remainder unlocks continuously, second by second, until the
///         schedule completes. The vesting curve itself is the rate limit —
///         no separate window cap is needed.
///
///         The beneficiary address is set once at construction and cannot be
///         changed. The contract has no owner and no upgrade path — nothing can
///         reroute or accelerate the allocation.
contract DevVesting {
    using SafeERC20 for IERC20;

    /// @notice Duration tokens are fully frozen from deploy time.
    uint256 public constant CLIFF = 182 days;

    /// @notice Total vesting duration measured from deploy time.
    uint256 public constant DURATION = 365 days * 4;

    IERC20 public immutable token;
    address public immutable beneficiary;

    /// @notice Timestamp the schedule starts (deploy time).
    uint256 public immutable start;

    /// @notice Timestamp the cliff ends. Before this, nothing is withdrawable.
    uint256 public immutable cliffEnd;

    /// @notice Timestamp the allocation is fully vested.
    uint256 public immutable end;

    /// @notice Total amount this contract is intended to vest — fixed at
    ///         construction. Withdrawals are additionally bounded by the
    ///         actual token balance, so under-funding simply makes the
    ///         contract unwithdrawable rather than inflating anything.
    uint256 public immutable allocation;

    /// @notice Total tokens withdrawn so far.
    uint256 public withdrawn;

    error ZeroAddress();
    error ZeroAllocation();
    error StillLocked(uint256 cliffEnd);
    error NotVested(uint256 requested, uint256 transferable);
    error NothingToWithdraw();

    event Withdrawn(address indexed to, uint256 amount);

    constructor(IERC20 token_, address beneficiary_, uint256 allocation_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) {
            revert ZeroAddress();
        }
        if (allocation_ == 0) revert ZeroAllocation();
        token = token_;
        beneficiary = beneficiary_;
        allocation = allocation_;
        start = block.timestamp;
        cliffEnd = block.timestamp + CLIFF;
        end = block.timestamp + DURATION;
    }

    /// @notice Tokens vested by the schedule at `timestamp`. Before the cliff
    ///         the vested amount still reports zero — it only becomes real on
    ///         the cliff date.
    function vested(uint256 timestamp) public view returns (uint256) {
        if (timestamp < cliffEnd) return 0;
        if (timestamp >= end) return allocation;
        return (allocation * (timestamp - start)) / DURATION;
    }

    /// @notice Max tokens withdrawable right now.
    function transferable() public view returns (uint256) {
        uint256 claimable = vested(block.timestamp) - withdrawn;
        uint256 balance = token.balanceOf(address(this));
        return claimable < balance ? claimable : balance;
    }

    /// @notice Withdraw `amount` tokens to the beneficiary. Reverts before the
    ///         cliff and when `amount` exceeds the vested-and-unwithdrawn
    ///         remainder. Permissionless — anyone may trigger the release;
    ///         tokens can only ever go to the immutable beneficiary.
    function withdraw(uint256 amount) external {
        if (block.timestamp < cliffEnd) revert StillLocked(cliffEnd);
        if (amount == 0) revert NothingToWithdraw();
        if (amount > transferable()) {
            revert NotVested(amount, transferable());
        }
        _withdraw(amount);
    }

    /// @notice Withdraw everything currently transferable. Permissionless —
    ///         the call a vesting keeper bot makes on schedule.
    function withdrawAll() external {
        uint256 amount = transferable();
        if (amount == 0) revert NothingToWithdraw();
        _withdraw(amount);
    }

    function _withdraw(uint256 amount) internal {
        withdrawn += amount;
        token.safeTransfer(beneficiary, amount);
        emit Withdrawn(beneficiary, amount);
    }
}
