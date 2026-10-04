// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

interface ICrossDomainMessenger {
    function sendMessage(address _target, bytes calldata _message, uint32 _minGasLimit) external payable;
    function xDomainMessageSender() external view returns (address);
}

interface IOMNIL2Bridge {
    function finalizeDeposit(address _to, uint256 _amount) external;
}

/// @title OMNIL1Bridge
/// @notice Application-layer bridge for the OMNICOR custom gas token (CGT v2).
///         Deposits lock OMNI ERC-20 on L1 and trigger a native-OMNI mint on L2
///         via the L2-side OMNIL2Bridge (an authorized LiquidityController minter).
///         Withdrawals release locked OMNI after the L2 native asset has been
///         burned into NativeAssetLiquidity by the L2 bridge.
/// @dev The contract is immutable and has no admin keys. Escrowed OMNI can only
///      leave through a proven withdrawal message relayed by the canonical
///      L1CrossDomainMessenger from the paired L2 bridge.
contract OMNIL1Bridge {
    using SafeERC20 for IERC20;

    /// @notice Emitted when OMNI is locked on L1 for a deposit to L2.
    event DepositInitiated(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when OMNI is released on L1 after a proven L2 burn.
    event WithdrawalFinalized(address indexed to, uint256 amount);

    /// @notice Thrown when the caller is not the L1CrossDomainMessenger or the
    ///         cross-domain sender is not the paired L2 bridge.
    error Unauthorized();

    /// @notice Thrown when a zero amount is supplied.
    error ZeroAmount();

    /// @notice Thrown when the L2 gas limit for the relayed message is zero —
    ///         such a message can never be executed on L2 and the deposit
    ///         would sit unclaimable until a replay with a real limit.
    error ZeroGasLimit();

    /// @notice Thrown when a required address is zero. These bridges are
    ///         immutable — a misconfigured address can never be repaired,
    ///         so every entry point validates eagerly.
    error ZeroAddress();

    /// @notice The OMNI ERC-20 token on L1.
    IERC20 public immutable OMNI;

    /// @notice The canonical L1 cross-domain messenger.
    ICrossDomainMessenger public immutable MESSENGER;

    /// @notice The paired OMNIL2Bridge contract address on L2.
    address public immutable L2_BRIDGE;

    /// @param _omni L1 OMNI ERC-20 token address.
    /// @param _messenger L1CrossDomainMessenger proxy address.
    /// @param _l2Bridge OMNIL2Bridge address on L2.
    constructor(address _omni, address _messenger, address _l2Bridge) {
        if (_omni == address(0) || _messenger == address(0) || _l2Bridge == address(0)) {
            revert ZeroAddress();
        }
        OMNI = IERC20(_omni);
        MESSENGER = ICrossDomainMessenger(_messenger);
        L2_BRIDGE = _l2Bridge;
    }

    /// @notice Locks OMNI on L1 and mints native OMNI to the caller on L2.
    /// @param _amount Amount of OMNI to deposit (18 decimals).
    /// @param _minGasLimit Minimum gas limit for the L2 finalizeDeposit call.
    function deposit(uint256 _amount, uint32 _minGasLimit) external {
        _deposit(msg.sender, _amount, _minGasLimit);
    }

    /// @notice Locks OMNI on L1 and mints native OMNI to `_to` on L2.
    /// @param _to Recipient of native OMNI on L2.
    /// @param _amount Amount of OMNI to deposit (18 decimals).
    /// @param _minGasLimit Minimum gas limit for the L2 finalizeDeposit call.
    function depositTo(address _to, uint256 _amount, uint32 _minGasLimit) external {
        if (_to == address(0)) revert ZeroAddress();
        _deposit(_to, _amount, _minGasLimit);
    }

    /// @notice Releases locked OMNI on L1. Callable only as a relayed message
    ///         from the paired OMNIL2Bridge via the canonical messenger.
    /// @param _to Recipient of the released OMNI ERC-20.
    /// @param _amount Amount to release.
    function finalizeWithdrawal(address _to, uint256 _amount) external {
        if (msg.sender != address(MESSENGER) || MESSENGER.xDomainMessageSender() != L2_BRIDGE) {
            revert Unauthorized();
        }
        if (_to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        OMNI.safeTransfer(_to, _amount);
        emit WithdrawalFinalized(_to, _amount);
    }

    function _deposit(address _to, uint256 _amount, uint32 _minGasLimit) internal {
        if (_amount == 0) revert ZeroAmount();
        if (_minGasLimit == 0) revert ZeroGasLimit();
        OMNI.safeTransferFrom(msg.sender, address(this), _amount);
        MESSENGER.sendMessage(
            L2_BRIDGE, abi.encodeCall(IOMNIL2Bridge.finalizeDeposit, (_to, _amount)), _minGasLimit
        );
        emit DepositInitiated(msg.sender, _to, _amount);
    }
}
