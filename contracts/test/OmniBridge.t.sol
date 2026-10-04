// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {OMNIL1Bridge} from "../src/OMNIL1Bridge.sol";
import {OMNIL2Bridge} from "../src/OMNIL2Bridge.sol";
import {MockQuote} from "../src/MockQuote.sol";

/// @dev Stand-in for the canonical cross-domain messenger. sendMessage
///      records the outgoing call; xDomainMessageSender returns a preset
///      cross-chain sender so tests can impersonate the paired bridge.
contract MockMessenger {
    address public sender;
    address public lastTarget;
    bytes public lastMessage;
    uint32 public lastMinGas;
    uint256 public calls;

    function setXDomainSender(address s) external {
        sender = s;
    }

    function sendMessage(address _target, bytes calldata _message, uint32 _minGasLimit) external payable {
        lastTarget = _target;
        lastMessage = _message;
        lastMinGas = _minGasLimit;
        calls++;
    }

    function xDomainMessageSender() external view returns (address) {
        return sender;
    }
}

/// @dev Stand-in for the LiquidityController predeploy on the L2 side.
contract MockLiquidityController {
    address public mintedTo;
    uint256 public mintedAmount;
    uint256 public burned;

    function mint(address _to, uint256 _amount) external {
        mintedTo = _to;
        mintedAmount = _amount;
    }

    function burn() external payable {
        burned += msg.value;
    }
}

contract OmniBridgeTest is Test {
    OMNIL1Bridge l1Bridge;
    OMNIL2Bridge l2Bridge;
    MockMessenger l1Messenger;
    MockMessenger l2Messenger;
    MockLiquidityController lc;
    MockQuote omni; // OMNI ERC-20 stand-in (mintable mock)

    address constant LC_PREDEPLOY = 0x420000000000000000000000000000000000002a;
    address constant L2M_PREDEPLOY = 0x4200000000000000000000000000000000000007;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        omni = new MockQuote("OMNICOR", "OMNI");
        l1Messenger = new MockMessenger();
        l2Messenger = new MockMessenger();
        lc = new MockLiquidityController();

        l1Bridge = new OMNIL1Bridge(address(omni), address(l1Messenger), makeAddr("l2Bridge"));
        // etch mocks at the immutable predeploy addresses the L2 bridge reads
        vm.etch(LC_PREDEPLOY, address(lc).code);
        vm.etch(L2M_PREDEPLOY, address(l2Messenger).code);
        l2Bridge = new OMNIL2Bridge(address(l1Bridge));
    }

    // --- constructor validation ---

    function test_L1BridgeRejectsZeroAddresses() public {
        vm.expectRevert(OMNIL1Bridge.ZeroAddress.selector);
        new OMNIL1Bridge(address(0), address(l1Messenger), makeAddr("x"));
        vm.expectRevert(OMNIL1Bridge.ZeroAddress.selector);
        new OMNIL1Bridge(address(omni), address(0), makeAddr("x"));
        vm.expectRevert(OMNIL1Bridge.ZeroAddress.selector);
        new OMNIL1Bridge(address(omni), address(l1Messenger), address(0));
    }

    function test_L2BridgeRejectsZeroAddress() public {
        vm.expectRevert(OMNIL2Bridge.ZeroAddress.selector);
        new OMNIL2Bridge(address(0));
    }

    // --- L1 deposit path ---

    function test_DepositLocksAndRelays() public {
        omni.mint(alice, 100 ether);
        vm.startPrank(alice);
        omni.approve(address(l1Bridge), 100 ether);
        l1Bridge.deposit(40 ether, 200_000);
        vm.stopPrank();

        assertEq(omni.balanceOf(address(l1Bridge)), 40 ether);
        assertEq(omni.balanceOf(alice), 60 ether);
        assertEq(l1Messenger.calls(), 1);
        assertEq(l1Messenger.lastTarget(), l1Bridge.L2_BRIDGE());
        // message encodes finalizeDeposit(alice, 40e18)
        assertEq(
            l1Messenger.lastMessage(),
            abi.encodeWithSignature("finalizeDeposit(address,uint256)", alice, 40 ether)
        );
        assertEq(l1Messenger.lastMinGas(), 200_000);
    }

    function test_DepositToRejectsZeroRecipient() public {
        omni.mint(alice, 1 ether);
        vm.startPrank(alice);
        omni.approve(address(l1Bridge), 1 ether);
        vm.expectRevert(OMNIL1Bridge.ZeroAddress.selector);
        l1Bridge.depositTo(address(0), 1 ether, 200_000);
        vm.stopPrank();
    }

    function test_DepositZeroAmountReverts() public {
        vm.expectRevert(OMNIL1Bridge.ZeroAmount.selector);
        l1Bridge.deposit(0, 200_000);
    }

    function test_DepositZeroGasLimitReverts() public {
        // A zero min gas limit would produce an L2 message that can never
        // execute — the deposit would lock OMNI with no way to mint on L2.
        omni.mint(alice, 1 ether);
        vm.startPrank(alice);
        omni.approve(address(l1Bridge), 1 ether);
        vm.expectRevert(OMNIL1Bridge.ZeroGasLimit.selector);
        l1Bridge.deposit(1 ether, 0);
        vm.expectRevert(OMNIL1Bridge.ZeroGasLimit.selector);
        l1Bridge.depositTo(bob, 1 ether, 0);
        vm.stopPrank();
    }

    // --- L1 withdrawal release ---

    function test_FinalizeWithdrawalOnlyViaMessengerFromL2Bridge() public {
        omni.mint(address(l1Bridge), 50 ether);

        // wrong caller entirely
        vm.expectRevert(OMNIL1Bridge.Unauthorized.selector);
        l1Bridge.finalizeWithdrawal(bob, 10 ether);

        // messenger but wrong xDomain sender
        l1Messenger.setXDomainSender(makeAddr("impostor"));
        vm.prank(address(l1Messenger));
        vm.expectRevert(OMNIL1Bridge.Unauthorized.selector);
        l1Bridge.finalizeWithdrawal(bob, 10 ether);

        // proper relay: messenger + paired L2 bridge as xDomain sender
        l1Messenger.setXDomainSender(l1Bridge.L2_BRIDGE());
        vm.prank(address(l1Messenger));
        l1Bridge.finalizeWithdrawal(bob, 10 ether);
        assertEq(omni.balanceOf(bob), 10 ether);
        assertEq(omni.balanceOf(address(l1Bridge)), 40 ether);
    }

    function test_FinalizeWithdrawalZeroAmountReverts() public {
        // A zero-amount release would emit WithdrawalFinalized(0) — polluting
        // accounting without moving anything.
        l1Messenger.setXDomainSender(l1Bridge.L2_BRIDGE());
        vm.prank(address(l1Messenger));
        vm.expectRevert(OMNIL1Bridge.ZeroAmount.selector);
        l1Bridge.finalizeWithdrawal(bob, 0);
    }

    // --- L2 withdraw path ---

    function test_L2WithdrawBurnsAndRelays() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        l2Bridge.withdraw{value: 3 ether}(200_000);
        assertEq(MockLiquidityController(LC_PREDEPLOY).burned(), 3 ether);
        assertEq(MockMessenger(L2M_PREDEPLOY).calls(), 1);
        assertEq(MockMessenger(L2M_PREDEPLOY).lastTarget(), l2Bridge.L1_BRIDGE());
        assertEq(
            MockMessenger(L2M_PREDEPLOY).lastMessage(),
            abi.encodeWithSignature("finalizeWithdrawal(address,uint256)", alice, 3 ether)
        );
    }

    function test_L2WithdrawZeroValueReverts() public {
        vm.expectRevert(OMNIL2Bridge.ZeroAmount.selector);
        l2Bridge.withdraw(200_000);
    }

    function test_L2WithdrawZeroGasLimitReverts() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(OMNIL2Bridge.ZeroGasLimit.selector);
        l2Bridge.withdraw{value: 1 ether}(0);
        vm.expectRevert(OMNIL2Bridge.ZeroGasLimit.selector);
        l2Bridge.withdrawTo{value: 1 ether}(bob, 0);
        vm.stopPrank();
    }

    function test_L2FinalizeDepositZeroAmountReverts() public {
        MockMessenger(L2M_PREDEPLOY).setXDomainSender(address(l1Bridge));
        vm.prank(L2M_PREDEPLOY);
        vm.expectRevert(OMNIL2Bridge.ZeroAmount.selector);
        l2Bridge.finalizeDeposit(bob, 0);
    }

    function test_L2WithdrawToRejectsZeroRecipient() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(OMNIL2Bridge.ZeroAddress.selector);
        l2Bridge.withdrawTo{value: 1 ether}(address(0), 200_000);
    }

    // --- L2 finalize deposit ---

    function test_L2FinalizeDepositOnlyViaMessengerFromL1Bridge() public {
        vm.expectRevert(OMNIL2Bridge.Unauthorized.selector);
        l2Bridge.finalizeDeposit(bob, 1 ether);

        MockMessenger(L2M_PREDEPLOY).setXDomainSender(makeAddr("impostor"));
        vm.prank(L2M_PREDEPLOY);
        vm.expectRevert(OMNIL2Bridge.Unauthorized.selector);
        l2Bridge.finalizeDeposit(bob, 1 ether);

        MockMessenger(L2M_PREDEPLOY).setXDomainSender(address(l1Bridge));
        vm.prank(L2M_PREDEPLOY);
        l2Bridge.finalizeDeposit(bob, 7 ether);
        assertEq(MockLiquidityController(LC_PREDEPLOY).mintedTo(), bob);
        assertEq(MockLiquidityController(LC_PREDEPLOY).mintedAmount(), 7 ether);
    }

    function test_L2FinalizeDepositRejectsZeroRecipient() public {
        MockMessenger(L2M_PREDEPLOY).setXDomainSender(address(l1Bridge));
        vm.prank(L2M_PREDEPLOY);
        vm.expectRevert(OMNIL2Bridge.ZeroAddress.selector);
        l2Bridge.finalizeDeposit(address(0), 1 ether);
    }
}
