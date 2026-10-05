// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ReserveVesting
/// @notice Holds the 70% reserve allocation of OMNICOR and releases it to the
///         reserve beneficiary over 40 QUARTERLY tranches on a DECREASING
///         schedule: the first quarter unlocks the largest tranche, every
///         next quarter unlocks strictly less, and the tranches sum to
///         exactly the allocation.
///
///         Tranche weights follow a linear decay: quarter i (1-indexed)
///         carries weight (N - i + 1) where N = 40, so the weights are
///         40, 39, ..., 2, 1 with total N*(N+1)/2 = 820.
///         Quarter 1 therefore unlocks ~4.878% of the allocation and
///         quarter 40 unlocks ~0.122%.
///
///         Each tranche is released as a lump at the start of its quarter
///         and is claimable ONLY during that quarter. When the quarter
///         ends, whatever was not claimed is burned forever: `burnExpired`
///         forwards it to 0x...dEaD. This hardcodes the platform policy —
///         unsold/unclaimed quarterly releases are destroyed, not carried
///         over. The beneficiary address is set once at construction and
///         cannot be changed; no owner, no upgrade path.
contract ReserveVesting {
    using SafeERC20 for IERC20;

    /// @notice Canonical burn address — same as OMNIBurner.DEAD.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Number of quarterly tranches (40 x 90 days ~= 10 years).
    uint256 public constant PERIODS = 40;

    /// @notice Length of one tranche period.
    uint256 public constant PERIOD = 90 days;

    /// @notice Sum of all tranche weights: 40 + 39 + ... + 1.
    uint256 public constant TOTAL_WEIGHT = 820; // PERIODS * (PERIODS + 1) / 2

    IERC20 public immutable token;
    address public immutable beneficiary;

    /// @notice Timestamp the schedule starts (deploy time).
    uint256 public immutable start;

    /// @notice Timestamp the reserve is fully vested.
    uint256 public immutable end;

    /// @notice Total amount this contract is intended to vest — fixed at
    ///         construction. Claims are additionally bounded by the
    ///         actual token balance, so under-funding simply makes the
    ///         contract unclaimable rather than inflating anything.
    uint256 public immutable allocation;

    /// @notice Total tokens sent to the beneficiary so far.
    uint256 public withdrawn;

    /// @notice Total tokens burned by expiry so far.
    uint256 public burned;

    /// @notice How much was claimed from each tranche (0-indexed period).
    mapping(uint256 => uint256) public periodClaimed;

    /// @notice Expired tranches already settled (burned) up to this index.
    uint256 public nextBurnPeriod;

    error ZeroAddress();
    error ZeroAllocation();
    error NotVested(uint256 requested, uint256 transferable);
    error NothingToWithdraw();
    error BadQuarter(uint256 quarter);

    event Withdrawn(address indexed to, uint256 amount);
    event Burned(uint256 indexed period, uint256 amount);

    constructor(IERC20 token_, address beneficiary_, uint256 allocation_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) {
            revert ZeroAddress();
        }
        if (allocation_ == 0) revert ZeroAllocation();
        token = token_;
        beneficiary = beneficiary_;
        allocation = allocation_;
        start = block.timestamp;
        end = block.timestamp + PERIODS * PERIOD;
    }

    /// @notice Index of the quarter in progress at `timestamp` (0-based).
    ///         Returns PERIODS after the schedule has fully elapsed.
    function periodAt(uint256 timestamp) public view returns (uint256) {
        if (timestamp <= start) return 0;
        uint256 elapsed = timestamp - start;
        uint256 q = elapsed / PERIOD;
        return q < PERIODS ? q : PERIODS;
    }

    /// @notice Size of the tranche released at the start of quarter `i`
    ///         (1-indexed).
    function tranche(uint256 i) public view returns (uint256) {
        if (i < 1 || i > PERIODS) revert BadQuarter(i);
        return (allocation * (PERIODS - i + 1)) / TOTAL_WEIGHT;
    }

    /// @notice Tokens released so far by the schedule (claimed or not,
    ///         burned or not). Kept for interface compatibility.
    function vested(uint256 timestamp) public view returns (uint256) {
        if (timestamp <= start) return 0;
        uint256 q = periodAt(timestamp);
        if (q >= PERIODS) return allocation;
        // weight of periods 0..q (current quarter is already released)
        uint256 w = (q + 1) * (2 * PERIODS - q) / 2;
        return (allocation * w) / TOTAL_WEIGHT;
    }

    /// @notice Max tokens claimable right now — only the CURRENT quarter's
    ///         unclaimed remainder; older tranches are expired and burnable.
    function transferable() public view returns (uint256) {
        uint256 q = periodAt(block.timestamp);
        if (q >= PERIODS) return 0;
        uint256 claimable = tranche(q + 1) - periodClaimed[q];
        uint256 balance = token.balanceOf(address(this));
        return claimable < balance ? claimable : balance;
    }

    /// @notice Withdraw `amount` tokens to the beneficiary. Permissionless —
    ///         anyone may trigger the release; tokens can only ever go to
    ///         the immutable beneficiary, so the caller gains nothing.
    ///         Expired leftovers are burned first: a new tranche can only
    ///         be claimed after the previous quarter's remainder is dead.
    function withdraw(uint256 amount) external {
        if (amount == 0) revert NothingToWithdraw();
        _burnExpired();
        if (amount > transferable()) {
            revert NotVested(amount, transferable());
        }
        _withdraw(amount);
    }

    /// @notice Withdraw everything currently claimable. Permissionless —
    ///         the call a vesting keeper bot makes on schedule. Burns
    ///         expired leftovers first, same as `withdraw`.
    function withdrawAll() external {
        _burnExpired();
        uint256 amount = transferable();
        if (amount == 0) revert NothingToWithdraw();
        _withdraw(amount);
    }

    /// @notice Burn every expired unclaimed tranche to the dead address.
    ///         Permissionless — anyone may settle expired quarters; the
    ///         tokens provably leave circulation forever. A tranche whose
    ///         quarter has ended can never be claimed again, so skipping
    ///         a period forfeits it regardless of later funding.
    function burnExpired() external {
        _burnExpired();
    }

    function _burnExpired() internal {
        uint256 q = periodAt(block.timestamp);
        uint256 balance = token.balanceOf(address(this));
        uint256 p = nextBurnPeriod;
        nextBurnPeriod = q;
        uint256 totalSend;
        for (; p < q; p++) {
            uint256 remainder = tranche(p + 1) - periodClaimed[p];
            if (remainder == 0) continue;
            uint256 send = remainder < balance ? remainder : balance;
            balance -= send;
            totalSend += send;
            emit Burned(p, send);
        }
        // Once every tranche has ended, sweep whatever is left — rounding
        // dust below the last tranche and any tokens sent by mistake.
        // Otherwise that remainder would be locked in the contract forever.
        if (q >= PERIODS && balance > 0) {
            totalSend += balance;
            emit Burned(PERIODS, balance);
        }
        if (totalSend > 0) {
            burned += totalSend;
            token.safeTransfer(DEAD, totalSend);
        }
    }

    function _withdraw(uint256 amount) internal {
        uint256 q = periodAt(block.timestamp);
        periodClaimed[q] += amount;
        withdrawn += amount;
        token.safeTransfer(beneficiary, amount);
        emit Withdrawn(beneficiary, amount);
    }
}
