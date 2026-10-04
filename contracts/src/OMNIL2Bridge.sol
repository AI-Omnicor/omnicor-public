// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICrossDomainMessenger {
    function sendMessage(address _target, bytes calldata _message, uint32 _minGasLimit) external payable;
    function xDomainMessageSender() external view returns (address);
}

interface ILiquidityController {
    function mint(address _to, uint256 _amount) external;
    function burn() external payable;
}

interface IOMNIL1Bridge {
    function finalizeWithdrawal(address _to, uint256 _amount) external;
}

/// @title OMNIL2Bridge
/// @notice L2 side of the OMNICOR custom gas token bridge. Must be registered
///         as an authorized minter on the LiquidityController predeploy.
///         finalizeDeposit releases native OMNI out of the NativeAssetLiquidity
///         reserve; withdraw burns native OMNI back into the reserve and sends
///         a zero-value withdrawal message that releases OMNI ERC-20 on L1.
/// @dev Immutable, no admin keys. Withdrawal messages carry zero native value
///      (required on CGT chains: L2ToL1MessagePasserCGT rejects value>0).
contract OMNIL2Bridge {
    /// @notice Emitted when native OMNI is minted to a user after an L1 lock.
    event DepositFinalized(address indexed to, uint256 amount);

    /// @notice Emitted when native OMNI is burned for a withdrawal to L1.
    event WithdrawalInitiated(address indexed from, address indexed to, uint256 amount);

    /// @notice Thrown when the caller is not the L2CrossDomainMessenger or the
    ///         cross-domain sender is not the paired L1 bridge.
    error Unauthorized();

    /// @notice Thrown when a zero amount is supplied.
    error ZeroAmount();

    /// @notice Thrown when the L1 gas limit for the relayed message is zero —
    ///         such a message can never be executed on L1.
    error ZeroGasLimit();

    /// @notice Thrown when a required address is zero. Immutable contract —
    ///         a zero pairing would strand deposits forever.
    error ZeroAddress();

    /// @notice LiquidityController predeploy.
    ILiquidityController public constant LIQUIDITY_CONTROLLER =
        ILiquidityController(0x420000000000000000000000000000000000002a);

    /// @notice L2CrossDomainMessenger predeploy.
    ICrossDomainMessenger public constant MESSENGER =
        ICrossDomainMessenger(0x4200000000000000000000000000000000000007);

    /// @notice The paired OMNIL1Bridge contract address on L1.
    address public immutable L1_BRIDGE;

    /// @param _l1Bridge OMNIL1Bridge address on L1.
    constructor(address _l1Bridge) {
        if (_l1Bridge == address(0)) revert ZeroAddress();
        L1_BRIDGE = _l1Bridge;
    }

    /// @notice Mints native OMNI on L2. Callable only as a relayed message from
    ///         the paired OMNIL1Bridge via the canonical messenger.
    /// @param _to Recipient of the native OMNI.
    /// @param _amount Amount of native OMNI to release from the reserve.
    function finalizeDeposit(address _to, uint256 _amount) external {
        if (msg.sender != address(MESSENGER) || MESSENGER.xDomainMessageSender() != L1_BRIDGE) {
            revert Unauthorized();
        }
        if (_to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        LIQUIDITY_CONTROLLER.mint(_to, _amount);
        emit DepositFinalized(_to, _amount);
    }

    /// @notice Burns native OMNI (msg.value) into the reserve and sends a
    ///         withdrawal message that releases OMNI ERC-20 to the caller on L1.
    /// @param _minGasLimit Minimum gas limit for the L1 finalizeWithdrawal call.
    function withdraw(uint32 _minGasLimit) external payable {
        _withdraw(msg.sender, _minGasLimit);
    }

    /// @notice Burns native OMNI (msg.value) and releases OMNI ERC-20 to `_to` on L1.
    /// @param _to Recipient of OMNI on L1.
    /// @param _minGasLimit Minimum gas limit for the L1 finalizeWithdrawal call.
    function withdrawTo(address _to, uint32 _minGasLimit) external payable {
        if (_to == address(0)) revert ZeroAddress();
        _withdraw(_to, _minGasLimit);
    }

    function _withdraw(address _to, uint32 _minGasLimit) internal {
        if (msg.value == 0) revert ZeroAmount();
        if (_minGasLimit == 0) revert ZeroGasLimit();
        LIQUIDITY_CONTROLLER.burn{ value: msg.value }();
        MESSENGER.sendMessage(
            L1_BRIDGE, abi.encodeCall(IOMNIL1Bridge.finalizeWithdrawal, (_to, msg.value)), _minGasLimit
        );
        emit WithdrawalInitiated(msg.sender, _to, msg.value);
    }
}
