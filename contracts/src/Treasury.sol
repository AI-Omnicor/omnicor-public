// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title OMNICORTreasury
/// @notice "OMNICOR Treasury" — on-chain reserve for the taxi platform's two
///         legal contours (RU / INTL). Holds native OMNI directly and is the
///         source for hot-wallet top-ups in reserve mode.
///
///         Two contours, each with:
///           - a hot executor key (server-held, signs platform operations)
///           - a cold corporate balance address (address recorded only; the
///             server never holds the cold key)
///
///         The owner (multisig in production, deployer in devnet) manages the
///         contour addresses and authorizes transfers. `topUpExecutor` sends
///         native OMNI to a contour's hot key; `sweepToCold` consolidates funds
///         to the contour's cold address. Rotating an executor or cold address
///         does not move funds — use topUpExecutor/sweepToCold for that.
contract OMNICORTreasury {
    using SafeERC20 for IERC20;

    /// @notice Legal contours served by the platform.
    uint8 public constant RU = 0;
    uint8 public constant INTL = 1;

    string public constant NAME = "OMNICOR Treasury";

    address public owner;

    /// @notice Pending owner in the two-step transfer. Must call
    ///         `acceptOwnership` to take over — an address that cannot
    ///         accept (dead key, wrong contract) never receives control.
    address public pendingOwner;

    /// @notice Hot executor addresses per contour (server-held keys).
    address public executorRU;
    address public executorINTL;

    /// @notice Cold corporate balance addresses per contour (address only —
    ///         keys never touch the server).
    address public coldRU;
    address public coldINTL;

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error BadContour();
    error ExecutorNotSet(uint8 contour);
    error ColdNotSet(uint8 contour);
    error TransferFailed();
    error ZeroAmount();

    event ExecutorUpdated(uint8 indexed contour, address indexed executor);
    event ColdWalletUpdated(uint8 indexed contour, address indexed cold);
    event ExecutorToppedUp(uint8 indexed contour, address indexed executor, uint256 amount);
    event SweptToCold(uint8 indexed contour, address indexed cold, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Deposited(address indexed from, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    /// @notice Reserve accepts native OMNI deposits (funding the reserve mode).
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Two-step handover: nominate, then the nominee accepts.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Set the hot executor address for a contour (0 = RU, 1 = INTL).
    function setExecutor(uint8 contour, address executor) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        if (contour == RU) executorRU = executor;
        else if (contour == INTL) executorINTL = executor;
        else revert BadContour();
        emit ExecutorUpdated(contour, executor);
    }

    /// @notice Set the cold corporate balance address for a contour.
    function setColdWallet(uint8 contour, address cold) external onlyOwner {
        if (cold == address(0)) revert ZeroAddress();
        if (contour == RU) coldRU = cold;
        else if (contour == INTL) coldINTL = cold;
        else revert BadContour();
        emit ColdWalletUpdated(contour, cold);
    }

    /// @notice Top up a contour's executor hot wallet from the reserve.
    function topUpExecutor(uint8 contour, uint256 amount) external onlyOwner {
        address executor = _executor(contour);
        if (executor == address(0)) revert ExecutorNotSet(contour);
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = executor.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ExecutorToppedUp(contour, executor, amount);
    }

    /// @notice Consolidate `amount` of the reserve into a contour's cold wallet.
    function sweepToCold(uint8 contour, uint256 amount) external onlyOwner {
        address cold = _cold(contour);
        if (cold == address(0)) revert ColdNotSet(contour);
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = cold.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit SweptToCold(contour, cold, amount);
    }

    /// @notice Rescue ERC-20 tokens sent here by mistake. Native OMNI is
    ///         NOT rescuable through this path — it moves only via
    ///         topUpExecutor/sweepToCold so the contour accounting stays
    ///         meaningful.
    function rescueTokens(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }

    function executor(uint8 contour) external view returns (address) {
        return _executor(contour);
    }

    function coldWallet(uint8 contour) external view returns (address) {
        return _cold(contour);
    }

    function _executor(uint8 contour) internal view returns (address) {
        if (contour == RU) return executorRU;
        if (contour == INTL) return executorINTL;
        revert BadContour();
    }

    function _cold(uint8 contour) internal view returns (address) {
        if (contour == RU) return coldRU;
        if (contour == INTL) return coldINTL;
        revert BadContour();
    }
}
