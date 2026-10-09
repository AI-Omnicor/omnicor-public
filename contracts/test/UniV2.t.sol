// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {UniswapV2Factory} from "../src/univ2/UniswapV2Factory.sol";
import {UniswapV2Pair} from "../src/univ2/UniswapV2Pair.sol";
import {UniswapV2Router02} from "../src/univ2/UniswapV2Router02.sol";
import {UniswapV2Library} from "../src/univ2/libraries/UniswapV2Library.sol";
import {IERC20 as IV2ERC20} from "../src/univ2/interfaces/IERC20.sol";
import {IUniswapV2Pair} from "../src/univ2/interfaces/IUniswapV2Pair.sol";
import {WOMNI} from "../src/WOMNI.sol";
import {MockQuote} from "../src/MockQuote.sol";

contract UniV2Test is Test {
    UniswapV2Factory factory;
    UniswapV2Router02 router;
    WOMNI womni;
    MockQuote usdt;
    address pair;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        factory = new UniswapV2Factory(address(this));
        womni = new WOMNI();
        router = new UniswapV2Router02(address(factory), address(womni));
        usdt = new MockQuote("Tether Mock", "USDT");
        pair = factory.createPair(address(womni), address(usdt));
        vm.deal(lp, 1000 ether);
        vm.deal(trader, 100 ether);
    }

    /// Prints the init code hash of this build — informational only; the
    /// value is environment-dependent (source keccaks feed the metadata
    /// hash), which is why pairFor derives it inline instead of a constant.
    function test_InitCodeHash() public view {
        bytes32 h = keccak256(type(UniswapV2Pair).creationCode);
        console2.log("INIT_CODE_PAIR_HASH:");
        console2.logBytes32(h);
    }

    /// pairFor must resolve to the address the factory actually deployed.
    function test_PairForMatchesFactory() public {
        address predicted = UniswapV2Library.pairFor(address(factory), address(womni), address(usdt));
        assertEq(predicted, pair, "pairFor must match factory.getPair");
        // Symmetric order.
        assertEq(UniswapV2Library.pairFor(address(factory), address(usdt), address(womni)), pair);
        assertEq(factory.getPair(address(womni), address(usdt)), pair);
        assertEq(factory.getPair(address(usdt), address(womni)), pair);
    }

    function test_TokenOrdering() public view {
        address t0 = IUniswapV2Pair(pair).token0();
        address t1 = IUniswapV2Pair(pair).token1();
        assertTrue(t0 < t1);
        assertTrue(t0 == address(womni) || t0 == address(usdt));
    }

    function _seed() internal {
        vm.startPrank(lp);
        womni.deposit{value: 100 ether}();
        womni.approve(address(router), type(uint256).max);
        usdt.mint(lp, 10000 ether);
        usdt.approve(address(router), type(uint256).max);
        router.addLiquidity(address(womni), address(usdt), 100 ether, 10000 ether, 0, 0, lp, block.timestamp + 60);
        vm.stopPrank();
    }

    function test_AddLiquidityMintsLP() public {
        _seed();
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        assertEq(uint256(r0) + uint256(r1), 100 ether + 10000 ether);
        assertGt(IUniswapV2Pair(pair).balanceOf(lp), 0);
        // canonical: minimum liquidity locked at address(0), not 0xdead
        assertEq(IUniswapV2Pair(pair).balanceOf(address(0)), 1000);
    }

    function test_RouterSwapExactIn() public {
        _seed();
        vm.startPrank(trader);
        usdt.mint(trader, 500 ether);
        usdt.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(womni);
        uint[] memory quoted = router.getAmountsOut(500 ether, path);
        uint[] memory amounts = router.swapExactTokensForTokens(500 ether, quoted[1], path, trader, block.timestamp + 60);
        vm.stopPrank();
        assertEq(womni.balanceOf(trader), amounts[1]);
        assertEq(amounts[1], quoted[1]);
        assertGt(amounts[1], 0);
    }

    function test_RouterSwapExactOut() public {
        _seed();
        vm.startPrank(trader);
        usdt.mint(trader, 5000 ether);
        usdt.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(womni);
        uint[] memory need = router.getAmountsIn(5 ether, path);
        uint[] memory amounts = router.swapTokensForExactTokens(5 ether, need[0], path, trader, block.timestamp + 60);
        vm.stopPrank();
        assertEq(womni.balanceOf(trader), 5 ether);
        assertEq(amounts[0], need[0]);
    }

    function test_SwapNativeForTokens() public {
        _seed();
        vm.startPrank(trader);
        address[] memory path = new address[](2);
        path[0] = address(womni);
        path[1] = address(usdt);
        uint[] memory quoted = router.getAmountsOut(1 ether, path);
        uint[] memory amounts = router.swapExactETHForTokens{value: 1 ether}(quoted[1], path, trader, block.timestamp + 60);
        vm.stopPrank();
        assertEq(usdt.balanceOf(trader), amounts[1]);
    }

    function test_RemoveLiquidityReturnsProRata() public {
        _seed();
        uint lpBal = IUniswapV2Pair(pair).balanceOf(lp);
        vm.startPrank(lp);
        IUniswapV2Pair(pair).approve(address(router), lpBal);
        uint usdtBefore = usdt.balanceOf(lp);
        (uint amtA, uint amtB) = router.removeLiquidity(address(womni), address(usdt), lpBal / 2, 0, 0, lp, block.timestamp + 60);
        vm.stopPrank();
        assertGt(amtA, 0);
        assertGt(amtB, 0);
        assertGt(usdt.balanceOf(lp), usdtBefore);
    }

    /// TWAP accumulators must advance — the feature SimplePair lacks.
    function test_PriceCumulativeAdvances() public {
        _seed();
        uint p0 = IUniswapV2Pair(pair).price0CumulativeLast();
        vm.warp(block.timestamp + 60);
        // any state-changing call updates the accumulator for the elapsed time
        vm.prank(lp);
        IUniswapV2Pair(pair).sync();
        assertGt(IUniswapV2Pair(pair).price0CumulativeLast(), p0);
    }

    /// Flash-swap callback: borrow without paying → must revert K check.
    function test_FlashSwapKEnforced() public {
        _seed();
        vm.expectRevert();
        IUniswapV2Pair(pair).swap(10 ether, 0, trader, "");
    }

    /// Protocol fee switch: feeTo receives LP growth after a fee-on accrual.
    function test_FeeToAccrual() public {
        address feeTo = makeAddr("feeTo");
        factory.setFeeTo(feeTo);
        _seed();
        uint kBefore = IUniswapV2Pair(pair).kLast();
        assertGt(kBefore, 0);
        // generate swap volume so sqrt(k) grows
        vm.startPrank(trader);
        usdt.mint(trader, 500 ether);
        usdt.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(womni);
        router.swapExactTokensForTokens(500 ether, 0, path, trader, block.timestamp + 60);
        vm.stopPrank();
        // a mint triggers _mintFee → feeTo receives newly minted LP
        vm.startPrank(lp);
        womni.deposit{value: 1 ether}();
        womni.transfer(pair, 1 ether);
        usdt.mint(address(pair), 100 ether);
        IUniswapV2Pair(pair).mint(lp);
        vm.stopPrank();
        assertGt(IUniswapV2Pair(pair).balanceOf(feeTo), 0, "feeTo must accrue LP on growth");
    }

    function test_DuplicatePairReverts() public {
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        factory.createPair(address(womni), address(usdt));
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        factory.createPair(address(usdt), address(womni));
    }

    function test_IdenticalAndZeroRejected() public {
        vm.expectRevert("UniswapV2: IDENTICAL_ADDRESSES");
        factory.createPair(address(womni), address(womni));
        vm.expectRevert("UniswapV2: ZERO_ADDRESS");
        factory.createPair(address(0), address(usdt));
    }

    /// Pair bytecode interface parity with the rehearsal SimplePair:
    /// integrators calling getReserves()/token0()/token1() see the same ABI.
    function test_PairAbiCompat() public {
        (bool ok0,) = pair.call(abi.encodeWithSignature("token0()"));
        (bool ok1,) = pair.call(abi.encodeWithSignature("token1()"));
        (bool okR, bytes memory res) = pair.call(abi.encodeWithSignature("getReserves()"));
        assertTrue(ok0 && ok1 && okR);
        assertEq(res.length, 96); // 3-word return: uint112, uint112, uint32
    }
}
