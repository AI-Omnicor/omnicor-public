// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {WOMNI} from "../src/WOMNI.sol";
import {OMNIBurner} from "../src/OMNIBurner.sol";
import {SimplePair} from "../src/SimplePair.sol";
import {MockQuote} from "../src/MockQuote.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract AppLayerTest is Test {
    WOMNI womni;
    OMNIBurner burner;
    MockQuote quote;
    SimplePair pair;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        womni = new WOMNI();
        burner = new OMNIBurner();
        quote = new MockQuote("Tether Mock", "USDT");
        pair = new SimplePair(IERC20(address(womni)), IERC20(address(quote)));
        vm.deal(lp, 1000 ether);
        vm.deal(trader, 100 ether);
    }

    // --- WOMNI ---

    function test_WomniRoundTrip() public {
        vm.startPrank(lp);
        womni.deposit{value: 10 ether}();
        assertEq(womni.balanceOf(lp), 10 ether);
        womni.withdraw(4 ether);
        assertEq(womni.balanceOf(lp), 6 ether);
        assertEq(lp.balance, 994 ether);
        vm.stopPrank();
    }

    // --- OMNIBurner ---

    function test_BurnDirectCounts() public {
        vm.prank(lp);
        burner.burnDirect{value: 5 ether}();
        assertEq(burner.totalBurned(), 5 ether);
        assertEq(burner.DEAD().balance, 5 ether);
    }

    function test_SweepBurnsBalance() public {
        vm.deal(address(burner), 3 ether);
        burner.sweep();
        assertEq(burner.totalBurned(), 3 ether);
        assertEq(address(burner).balance, 0);
    }

    // --- SimplePair liquidity + swap ---

    function _seedPool(uint256 w, uint256 q) internal {
        vm.startPrank(lp);
        womni.deposit{value: w}();
        womni.transfer(address(pair), w);
        quote.mint(lp, q);
        quote.transfer(address(pair), q);
        pair.mint(lp);
        vm.stopPrank();
    }

    function test_PoolMintAndReserves() public {
        _seedPool(100 ether, 1000 ether);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 100 ether);
        assertEq(r1, 1000 ether);
        assertGt(pair.balanceOf(lp), 0);
        assertEq(pair.balanceOf(address(0xdead)), 1000); // locked minimum
    }

    function test_SwapRespectsInvariant() public {
        _seedPool(100 ether, 1000 ether);
        // getAmountOut(amountIn, tokenIn) quotes OUT for IN: send
        // quote in, take womni out. Quote how much out for 120 USDT in.
        uint256 out = pair.getAmountOut(120 ether, address(quote));
        vm.startPrank(trader);
        quote.mint(trader, 120 ether);
        quote.transfer(address(pair), 120 ether);
        pair.swap(out, 0, trader);
        vm.stopPrank();
        assertEq(womni.balanceOf(trader), out);
        assertGt(out, 0);
    }

    function test_PureQuoteMatchesReserveOverload() public {
        _seedPool(50 ether, 500 ether);
        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 a = pair.getAmountOut(1 ether, address(quote)); // reserve path
        uint256 b = pair.getAmountOut(1 ether, uint256(r1), uint256(r0)); // pure path
        assertEq(a, b);
    }

    function test_KCheckBlocksCheapSwap() public {
        _seedPool(10 ether, 100 ether);
        // try to extract without paying in -> must revert InsufficientInput
        vm.expectRevert(SimplePair.InsufficientInput.selector);
        pair.swap(1 ether, 0, trader);
    }

    function test_SwapRejectsTokenAddressesAsRecipient() public {
        // UniV2 parity: paying swap output to either token address would
        // strand the tokens inside the token contract.
        _seedPool(10 ether, 100 ether);
        quote.mint(trader, 10 ether);
        vm.startPrank(trader);
        quote.transfer(address(pair), 10 ether);
        vm.expectRevert(SimplePair.InvalidRecipient.selector);
        pair.swap(1 ether, 0, address(womni));
        vm.expectRevert(SimplePair.InvalidRecipient.selector);
        pair.swap(0, 1 ether, address(quote));
        vm.stopPrank();
    }

    // --- Price / quote edge cases ---

    function test_PriceHandlesOneSidedReserve() public {
        // token0 side empty -> price0() divides by reserve0; must return 0,
        // not revert with a division panic.
        assertEq(pair.price0(), 0);
        assertEq(pair.price1(), 0);

        _seedPool(0.001 ether, 1 ether);
        vm.prank(lp);
        womni.deposit{value: 1 ether}(); // unrelated balance, pool unchanged
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        assertEq(pair.price0(), (uint256(r1) * 1e18) / uint256(r0));
        assertEq(pair.price1(), (uint256(r0) * 1e18) / uint256(r1));
    }

    function test_QuoteRejectsForeignToken() public {
        _seedPool(10 ether, 100 ether);
        address foreign = makeAddr("foreign-token");
        vm.expectRevert(abi.encodeWithSelector(SimplePair.UnknownToken.selector, foreign));
        pair.getAmountOut(1 ether, foreign);
    }

    function test_ZeroReserveQuoteReverts() public {
        vm.expectRevert("SimplePair: INSUFFICIENT_LIQUIDITY");
        pair.getAmountOut(1 ether, address(womni));
    }

    // --- Constructor validation ---

    function test_PairRejectsZeroAndIdenticalTokens() public {
        vm.expectRevert(SimplePair.ZeroAddress.selector);
        new SimplePair(IERC20(address(0)), IERC20(address(quote)));
        vm.expectRevert(SimplePair.ZeroAddress.selector);
        new SimplePair(IERC20(address(womni)), IERC20(address(0)));
        vm.expectRevert(SimplePair.IdenticalTokens.selector);
        new SimplePair(IERC20(address(quote)), IERC20(address(quote)));
    }

    // --- Reserve overflow ---

    function test_SyncRejectsBalanceOverUint112() public {
        // uint112.max + 1 of the quote token must not silently truncate.
        quote.mint(address(pair), uint256(type(uint112).max) + 1);
        vm.expectRevert(SimplePair.Overflow.selector);
        pair.sync();
    }

    // --- Reentrancy ---

    function test_LockBlocksReentrantSwap() public {
        ReentrantERC20 evil = new ReentrantERC20();
        SimplePair p2 = new SimplePair(IERC20(address(evil)), IERC20(address(quote)));
        evil.setTarget(p2);
        evil.mint(lp, 100 ether);
        quote.mint(lp, 100 ether);
        vm.startPrank(lp);
        evil.transfer(address(p2), 50 ether);
        quote.transfer(address(p2), 50 ether);
        p2.mint(lp);
        evil.mint(trader, 1 ether);
        vm.stopPrank();
        // evil token is token0: swap must pay IT out so its transfer hook
        // fires and tries to reenter swap() -> Locked -> outer tx reverts.
        vm.prank(trader);
        evil.transfer(address(p2), 1 ether);
        vm.prank(trader);
        vm.expectRevert();
        p2.swap(0.5 ether, 0, trader);
    }

    // --- Non-standard ERC20 (USDT-style: no return values) ---

    function test_PairWithNonStandardToken() public {
        NoReturnERC20 nr = new NoReturnERC20();
        SimplePair p2 = new SimplePair(IERC20(address(nr)), IERC20(address(quote)));
        nr.mint(lp, 100e6);
        quote.mint(lp, 100e18);
        vm.startPrank(lp);
        nr.transfer(address(p2), 100e6);
        quote.transfer(address(p2), 100e18);
        p2.mint(lp); // SafeERC20 handles missing return values
        vm.stopPrank();
        (uint112 r0, uint112 r1) = p2.getReserves();
        assertEq(uint256(r0), 100e6);
        assertEq(uint256(r1), 100e18);

        // Exercise the OUTGOING safeTransfer path too: buy the no-return
        // token out of the pair (the previous test only deposited into it).
        nr.mint(trader, 0); // keep trader minted count at zero
        uint256 nrOut = p2.getAmountOut(10e18, address(quote));
        vm.startPrank(trader);
        quote.mint(trader, 10e18);
        quote.transfer(address(p2), 10e18);
        p2.swap(nrOut, 0, trader);
        vm.stopPrank();
        assertEq(nr.balanceOf(trader), nrOut);
        assertGt(nrOut, 0);
    }
}

/// @dev ERC-777-style malicious token: reenters the pair's swap during an
///      outgoing transfer. The lock must reject the nested call.
contract ReentrantERC20 {
    mapping(address => uint256) public balanceOf;
    SimplePair public target;
    bool public armed = true;

    function setTarget(SimplePair p) external {
        target = p;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (armed && to != address(target)) {
            armed = false; // single reentry attempt, then behave
            try target.swap(0, 1, to) { } catch { }
            // propagate failure so the test can observe the reverted payout
            revert("reentrant-call-finished");
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev USDT-style ERC20: transfer/transferFrom return no value.
contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address from, address to, uint256 a) external {
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}
