// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {OMNIBurner} from "../src/OMNIBurner.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {OMNICORTreasury} from "../src/Treasury.sol";

contract FeeSplitterTest is Test {
    OMNIBurner burner;
    OMNICORTreasury treasury;
    FeeSplitter splitter;
    address owner = makeAddr("safe-owner");
    address anybody = makeAddr("anybody");

    function setUp() public {
        burner = new OMNIBurner();
        treasury = new OMNICORTreasury(owner);
        splitter = new FeeSplitter(burner, address(treasury));
    }

    function test_SweepSplitsSeventyThirty() public {
        vm.deal(address(splitter), 100 ether);
        vm.prank(anybody); // permissionless trigger, like the keeper bot
        splitter.sweep();
        assertEq(burner.DEAD().balance, 70 ether);
        assertEq(burner.totalBurned(), 70 ether);
        assertEq(address(treasury).balance, 30 ether);
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.totalBurned(), 70 ether);
        assertEq(splitter.totalToTreasury(), 30 ether);
    }

    function test_TreasuryKeepsRemainderOnOddAmount() public {
        // 100 wei: burn = 70, treasury = 30 — rounding never strands dust.
        vm.deal(address(splitter), 100);
        splitter.sweep();
        assertEq(burner.DEAD().balance, 70);
        assertEq(address(treasury).balance, 30);
    }

    function test_TinyBalanceAllGoesToTreasury() public {
        // 1 wei: burn share rounds to 0 — burnDirect(0) must not be called.
        vm.deal(address(splitter), 1);
        splitter.sweep();
        assertEq(address(treasury).balance, 1);
        assertEq(burner.DEAD().balance, 0);
    }

    function test_SweepRevertsWhenEmpty() public {
        vm.expectRevert(FeeSplitter.NothingToSplit.selector);
        splitter.sweep();
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(OMNIBurner(payable(address(0))), address(treasury));
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(burner, address(0));
    }

    function test_RatioIsHardcoded() public {
        // Platform policy: 70% of every swept amount is burned, 30% kept.
        assertEq(splitter.BURN_BPS(), 7_000);
        assertEq(splitter.BPS(), 10_000);
    }
}
