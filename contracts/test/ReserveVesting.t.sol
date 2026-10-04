// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {OMNICORToken} from "../src/OMNICORToken.sol";
import {ReserveVesting} from "../src/ReserveVesting.sol";

contract ReserveVestingTest is Test {
    OMNICORToken token;
    ReserveVesting vesting;
    address reserve = makeAddr("reserve");
    address rando = makeAddr("rando");

    uint256 constant RESERVE_ALLOCATION = 700_000_000e18; // 70% of 1B
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        token = new OMNICORToken("OMNICOR", "OMNI", address(this));
        vesting = new ReserveVesting(token, reserve, RESERVE_ALLOCATION);
        token.transfer(address(vesting), RESERVE_ALLOCATION);
    }

    function test_DecreasingTranchesSumToAllocation() public {
        uint256 sum;
        uint256 prev = type(uint256).max;
        for (uint256 i = 1; i <= 40; i++) {
            uint256 t = vesting.tranche(i);
            assertLt(t, prev, "tranches must strictly decrease");
            prev = t;
            sum += t;
        }
        // rounding dust: sum may be a few wei below allocation
        assertApproxEqAbs(sum, RESERVE_ALLOCATION, 100, "tranches must sum to ~70%");
        assertLe(sum, RESERVE_ALLOCATION);
    }

    function test_FirstTrancheIsLargest() public {
        uint256 first = vesting.tranche(1);
        uint256 last = vesting.tranche(40);
        // 40/820 = ~4.878% of allocation vs 1/820 = ~0.122%
        assertEq(first, RESERVE_ALLOCATION * 40 / 820);
        assertEq(last, RESERVE_ALLOCATION / 820);
        assertGt(first, last * 30);
    }

    function test_FirstTrancheOpenAtDeploy() public {
        // Lump release: quarter 1 is claimable immediately at deploy.
        assertEq(vesting.transferable(), vesting.tranche(1));
    }

    function test_QuarterBoundaries() public {
        uint256 start = vesting.start();
        vm.warp(start + 90 days); // quarter 2 begins
        assertApproxEqAbs(
            vesting.vested(block.timestamp),
            vesting.tranche(1) + vesting.tranche(2),
            1
        );
        vm.warp(start + 180 days); // quarter 3
        assertApproxEqAbs(
            vesting.vested(block.timestamp),
            vesting.tranche(1) + vesting.tranche(2) + vesting.tranche(3),
            1
        );
    }

    function test_FullyVestedAtEnd() public {
        vm.warp(vesting.end());
        assertEq(vesting.vested(block.timestamp), RESERVE_ALLOCATION);
        vm.warp(vesting.end() + 365 days);
        assertEq(vesting.vested(block.timestamp), RESERVE_ALLOCATION);
    }

    function test_WithdrawRespectsCurrentQuarter() public {
        uint256 t1 = vesting.transferable();
        assertGt(t1, 30_000_000e18, "quarter1 tranche ~34.1M");

        // Permissionless release: a keeper bot triggers, funds still
        // land only on the beneficiary.
        vm.prank(rando);
        vesting.withdraw(t1);
        assertEq(token.balanceOf(reserve), t1);
        assertEq(token.balanceOf(rando), 0);
        assertEq(vesting.transferable(), 0);
    }

    function test_UnclaimedTrancheBurnsAtQuarterEnd() public {
        uint256 start = vesting.start();
        uint256 t1 = vesting.tranche(1);

        vm.warp(start + 90 days); // quarter 2: tranche 1 expired
        // Only quarter 2's tranche is claimable — quarter 1 is gone.
        assertEq(vesting.transferable(), vesting.tranche(2));

        // Claim part of quarter 2, then expire the rest too.
        uint256 t2 = vesting.tranche(2);
        vesting.withdraw(t2 / 2);

        vm.warp(start + 180 days); // quarter 3
        // Permissionless burn: anyone can settle expired quarters.
        vm.prank(rando);
        vesting.burnExpired();
        assertEq(token.balanceOf(DEAD), t1 + t2 / 2);
        assertEq(vesting.burned(), t1 + t2 / 2);
        assertEq(vesting.transferable(), vesting.tranche(3));
    }

    function test_ExpiredTrancheCannotBeClaimed() public {
        uint256 start = vesting.start();
        uint256 t1 = vesting.tranche(1);
        vm.warp(start + 90 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVesting.NotVested.selector,
                t1,
                vesting.tranche(2)
            )
        );
        vesting.withdraw(t1);
    }

    function test_ClaimAllEveryQuarterEndsWithDustOnly() public {
        uint256 start = vesting.start();
        for (uint256 q = 0; q < 40; q++) {
            vm.warp(start + q * 90 days + 1);
            vesting.withdrawAll();
        }
        assertApproxEqAbs(token.balanceOf(reserve), RESERVE_ALLOCATION, 200);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_NewTrancheClaimBurnsOldRemainder() public {
        uint256 start = vesting.start();
        uint256 t1 = vesting.tranche(1);
        uint256 t2 = vesting.tranche(2);

        // Quarter 2 claim: old unclaimed remainder burns inline,
        // the new tranche releases only after it.
        vm.warp(start + 90 days);
        vm.prank(rando);
        vesting.withdrawAll();
        assertEq(token.balanceOf(DEAD), t1, "expired Q1 must burn on claim");
        assertEq(token.balanceOf(reserve), t2);
        assertEq(vesting.burned(), t1);
    }

    function test_EverythingUnclaimedBurnsAfterEnd() public {
        vm.warp(vesting.end() + 1);
        assertEq(vesting.transferable(), 0);
        vesting.burnExpired();
        // Final sweep sends rounding dust too — the whole balance is dead.
        assertEq(token.balanceOf(DEAD), RESERVE_ALLOCATION);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.balanceOf(reserve), 0);
    }

    function test_BurnExpiredIsIdempotent() public {
        uint256 start = vesting.start();
        uint256 t1 = vesting.tranche(1);
        vm.warp(start + 90 days);
        vesting.burnExpired();
        uint256 deadAfterFirst = token.balanceOf(DEAD);
        assertEq(deadAfterFirst, t1);
        // Second call must be a no-op — no double count, no revert.
        vesting.burnExpired();
        assertEq(token.balanceOf(DEAD), deadAfterFirst);
        assertEq(vesting.burned(), t1);
    }

    function test_MistakenTokensSweptAfterEnd() public {
        // A stranger sends extra tokens — they can't be claimed by anyone
        // and are swept to DEAD with the final settle, not locked forever.
        token.transfer(address(vesting), 123e18);
        vm.warp(vesting.end() + 1);
        vesting.burnExpired();
        assertEq(token.balanceOf(DEAD), RESERVE_ALLOCATION + 123e18);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_UnderfundedThenFundedStillBurnsExpired() public {
        // Deliberately under-funded vesting: 1% of allocation — less
        // than the first tranche (~34.1M), so the balance is the limit.
        OMNICORToken t2 = new OMNICORToken("OMNICOR", "OMNI", address(this));
        ReserveVesting partialV = new ReserveVesting(t2, reserve, RESERVE_ALLOCATION);
        uint256 seed = RESERVE_ALLOCATION / 100;
        t2.transfer(address(partialV), seed);

        // Claimable bounded by the actual balance even in quarter 1.
        assertEq(partialV.transferable(), seed);
        partialV.withdrawAll();
        assertEq(t2.balanceOf(reserve), seed);

        // Warp past quarter 1 — its unclaimed remainder expired; late
        // funding cannot resurrect it, it burns on settlement.
        t2.transfer(address(partialV), RESERVE_ALLOCATION - seed);
        vm.warp(partialV.start() + 90 days);
        uint256 unclaimedQ1 = partialV.tranche(1) - seed;
        assertEq(partialV.transferable(), partialV.tranche(2));
        partialV.burnExpired();
        assertEq(t2.balanceOf(DEAD), unclaimedQ1);
    }
}
