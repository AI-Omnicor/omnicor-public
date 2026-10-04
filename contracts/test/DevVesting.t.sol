// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {OMNICORToken} from "../src/OMNICORToken.sol";
import {DevVesting} from "../src/DevVesting.sol";

contract DevVestingTest is Test {
    OMNICORToken token;
    DevVesting vesting;
    address dev = makeAddr("dev");
    address rando = makeAddr("rando");

    uint256 constant DEV_ALLOCATION = 200_000_000e18; // 20% of 1B

    function setUp() public {
        token = new OMNICORToken("OMNICOR", "OMNI", address(this));
    }

    function _freshVesting() internal returns (DevVesting v) {
        v = new DevVesting(token, dev, DEV_ALLOCATION);
        token.transfer(address(v), DEV_ALLOCATION);
    }

    function test_NothingTransferableBeforeCliff() public {
        DevVesting v = _freshVesting();
        assertEq(v.transferable(), 0);

        // One second before the cliff: still zero.
        vm.warp(v.cliffEnd() - 1);
        assertEq(v.transferable(), 0);

        vm.expectRevert(abi.encodeWithSelector(DevVesting.StillLocked.selector, v.cliffEnd()));
        vm.prank(dev);
        v.withdraw(1);
    }

    function test_CliffUnlocksAccruedShare() public {
        DevVesting v = _freshVesting();
        vm.warp(v.cliffEnd());

        // 182 days of the 1460-day schedule vested at once.
        uint256 expected = (DEV_ALLOCATION * v.CLIFF()) / v.DURATION();
        assertEq(v.transferable(), expected);
        assertGt(expected, 0);

        vm.prank(dev);
        v.withdrawAll();
        assertEq(token.balanceOf(dev), expected);
        assertEq(v.transferable(), 0);
    }

    function test_LinearVestingAfterCliff() public {
        DevVesting v = _freshVesting();
        uint256 t0 = v.cliffEnd();
        vm.warp(t0);
        vm.prank(dev);
        v.withdrawAll();
        uint256 firstTranche = token.balanceOf(dev);

        // 30 days later another pro-rata slice is available.
        vm.warp(t0 + 30 days);
        uint256 monthly = (DEV_ALLOCATION * 30 days) / v.DURATION();
        uint256 transferable = v.transferable();
        // Integer division can shave a wei; allow 1 wei tolerance.
        assertApproxEqAbs(transferable, monthly, 1);

        vm.prank(dev);
        v.withdrawAll();
        assertApproxEqAbs(token.balanceOf(dev), firstTranche + monthly, 1);
    }

    function test_CannotOutrunSchedule() public {
        DevVesting v = _freshVesting();
        vm.warp(v.cliffEnd() + 30 days);
        uint256 cap = v.transferable();

        vm.prank(dev);
        vm.expectRevert(
            abi.encodeWithSelector(DevVesting.NotVested.selector, cap + 1, cap)
        );
        v.withdraw(cap + 1);
    }

    function test_AnyoneCanTriggerReleaseToBeneficiary() public {
        DevVesting v = _freshVesting();
        vm.warp(v.cliffEnd() + 1 days);
        uint256 amt = v.transferable();
        assertGt(amt, 0);

        // A keeper bot (any address) can trigger the release, but the
        // tokens can only ever land on the beneficiary.
        vm.prank(rando);
        v.withdrawAll();
        assertEq(token.balanceOf(dev), amt);
        assertEq(token.balanceOf(rando), 0);

        // Same for a partial withdraw triggered by a third party.
        vm.warp(block.timestamp + 30 days);
        uint256 amt2 = v.transferable();
        vm.prank(rando);
        v.withdraw(amt2);
        assertEq(token.balanceOf(dev), amt + amt2);
        assertEq(token.balanceOf(rando), 0);
    }

    function test_FullyVestedAtEnd() public {
        DevVesting v = _freshVesting();
        vm.warp(v.end());
        assertEq(v.transferable(), DEV_ALLOCATION);
        vm.prank(dev);
        v.withdrawAll();
        assertEq(token.balanceOf(dev), DEV_ALLOCATION);
        assertEq(v.transferable(), 0);
    }

    function test_NoBackdoors() public {
        // No owner, no upgrade, no rescue: token address and beneficiary are
        // immutable, schedule bounds are constants.
        DevVesting v = _freshVesting();
        assertEq(v.beneficiary(), dev);
        assertEq(address(v.token()), address(token));
        assertEq(v.DURATION(), 1460 days);
        assertEq(v.CLIFF(), 182 days);
    }
}
