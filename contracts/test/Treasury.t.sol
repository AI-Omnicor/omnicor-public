// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {OMNICORTreasury} from "../src/Treasury.sol";

contract TreasuryTest is Test {
    OMNICORTreasury treasury;
    address owner = makeAddr("owner");
    address execRU = makeAddr("execRU");
    address execINTL = makeAddr("execINTL");
    address coldRU = makeAddr("coldRU");
    address coldINTL = makeAddr("coldINTL");
    address rando = makeAddr("rando");

    function setUp() public {
        treasury = new OMNICORTreasury(owner);
        vm.deal(address(this), 100 ether);
    }

    uint8 constant RU = 0;
    uint8 constant INTL = 1;

    function _configure() internal {
        vm.startPrank(owner);
        treasury.setExecutor(RU, execRU);
        treasury.setExecutor(INTL, execINTL);
        treasury.setColdWallet(RU, coldRU);
        treasury.setColdWallet(INTL, coldINTL);
        vm.stopPrank();
    }

    function test_HoldsNativeOMNI() public {
        (bool ok,) = address(treasury).call{value: 50 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 50 ether);
    }

    function test_TopUpExecutor() public {
        _configure();
        (bool ok,) = address(treasury).call{value: 10 ether}("");
        assertTrue(ok);

        vm.prank(owner);
        treasury.topUpExecutor(RU, 3 ether);
        assertEq(execRU.balance, 3 ether);
        assertEq(address(treasury).balance, 7 ether);
    }

    function test_SweepToCold() public {
        _configure();
        (bool ok,) = address(treasury).call{value: 10 ether}("");
        assertTrue(ok);

        vm.prank(owner);
        treasury.sweepToCold(INTL, 4 ether);
        assertEq(coldINTL.balance, 4 ether);
    }

    function test_OnlyOwnerCanConfigure() public {
        vm.prank(rando);
        vm.expectRevert(OMNICORTreasury.NotOwner.selector);
        treasury.setExecutor(RU, rando);

        vm.prank(rando);
        vm.expectRevert(OMNICORTreasury.NotOwner.selector);
        treasury.topUpExecutor(RU, 1);
    }

    function test_BadContourReverts() public {
        vm.prank(owner);
        vm.expectRevert(OMNICORTreasury.BadContour.selector);
        treasury.setExecutor(2, execRU);

        vm.prank(owner);
        vm.expectRevert(OMNICORTreasury.BadContour.selector);
        treasury.topUpExecutor(9, 1 ether);
    }

    function test_UnsetExecutorReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OMNICORTreasury.ExecutorNotSet.selector, uint8(0)));
        treasury.topUpExecutor(RU, 1 ether);
    }

    function test_OwnershipTransfer() public {
        vm.prank(owner);
        treasury.transferOwnership(rando);
        assertEq(treasury.owner(), owner);
        assertEq(treasury.pendingOwner(), rando);

        vm.prank(rando);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), rando);
        assertEq(treasury.pendingOwner(), address(0));
    }

    function test_OwnershipTransferRequiresAcceptance() public {
        vm.prank(owner);
        treasury.transferOwnership(rando);

        vm.prank(execRU);
        vm.expectRevert(OMNICORTreasury.NotPendingOwner.selector);
        treasury.acceptOwnership();

        // old owner still in control until the nominee accepts
        vm.prank(owner);
        treasury.setExecutor(RU, execRU);
    }

    function test_OwnershipToZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(OMNICORTreasury.ZeroAddress.selector);
        treasury.transferOwnership(address(0));
    }

    function test_ExecutorCallFailureReverts() public {
        RejectingExecutor rej = new RejectingExecutor();
        vm.prank(owner);
        treasury.setExecutor(RU, address(rej));
        (bool ok,) = address(treasury).call{value: 2 ether}("");
        assertTrue(ok);

        vm.prank(owner);
        vm.expectRevert(OMNICORTreasury.TransferFailed.selector);
        treasury.topUpExecutor(RU, 1 ether);
        assertEq(address(treasury).balance, 2 ether);
    }

    function test_UnsetColdReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OMNICORTreasury.ColdNotSet.selector, uint8(1)));
        treasury.sweepToCold(INTL, 1 ether);
    }

    function test_ZeroAmountReverts() public {
        _configure();
        vm.prank(owner);
        vm.expectRevert(OMNICORTreasury.ZeroAmount.selector);
        treasury.topUpExecutor(RU, 0);

        vm.prank(owner);
        vm.expectRevert(OMNICORTreasury.ZeroAmount.selector);
        treasury.sweepToCold(RU, 0);
    }

    function test_GettersByContour() public {
        _configure();
        assertEq(treasury.executor(RU), execRU);
        assertEq(treasury.executor(INTL), execINTL);
        assertEq(treasury.coldWallet(RU), coldRU);
        assertEq(treasury.coldWallet(INTL), coldINTL);
        vm.expectRevert(OMNICORTreasury.BadContour.selector);
        treasury.executor(5);
        vm.expectRevert(OMNICORTreasury.BadContour.selector);
        treasury.coldWallet(5);
    }

    function test_RescueTokens() public {
        MockERC20 junk = new MockERC20();
        junk.mint(address(treasury), 42 ether);

        vm.prank(owner);
        treasury.rescueTokens(IERC20(address(junk)), coldRU, 42 ether);
        assertEq(junk.balanceOf(coldRU), 42 ether);
        assertEq(junk.balanceOf(address(treasury)), 0);
    }

    function test_RescueTokensOnlyOwner() public {
        MockERC20 junk = new MockERC20();
        junk.mint(address(treasury), 1 ether);

        vm.prank(rando);
        vm.expectRevert(OMNICORTreasury.NotOwner.selector);
        treasury.rescueTokens(IERC20(address(junk)), rando, 1 ether);
    }
}

contract MockERC20 {
    string public name = "Junk";
    string public symbol = "JNK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RejectingExecutor {
    receive() external payable {
        revert("no thanks");
    }
}
