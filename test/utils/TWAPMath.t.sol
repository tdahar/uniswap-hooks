// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {TWAPMath} from "src/utils/TWAPMath.sol";

contract TWAPMathTest is Test {
    uint160 constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;
    uint160 constant SQRT_PRICE_2_1 = Constants.SQRT_PRICE_2_1;
    uint160 constant SQRT_PRICE_4_1 = Constants.SQRT_PRICE_4_1;
    uint160 constant SQRT_PRICE_1_4 = Constants.SQRT_PRICE_1_4;

    // --- Price conversions ---

    function test_amount0ToAmount1_atParity() public pure {
        assertEq(TWAPMath.amount0ToAmount1(1e18, SQRT_PRICE_1_1), 1e18);
    }

    function test_amount0ToAmount1_atPrice4() public pure {
        assertEq(TWAPMath.amount0ToAmount1(1e18, SQRT_PRICE_4_1), 4e18);
    }

    function test_amount0ToAmount1_atPriceOneQuarter() public pure {
        assertEq(TWAPMath.amount0ToAmount1(4e18, SQRT_PRICE_1_4), 1e18);
    }

    function test_amount0ToAmount1_roundsDown() public pure {
        assertEq(TWAPMath.amount0ToAmount1(3, SQRT_PRICE_1_4), 0);
    }

    function test_amount1ToAmount0_atParity() public pure {
        assertEq(TWAPMath.amount1ToAmount0(1e18, SQRT_PRICE_1_1), 1e18);
    }

    function test_amount1ToAmount0_zero() public pure {
        assertEq(TWAPMath.amount1ToAmount0(0, SQRT_PRICE_4_1), 0);
    }

    function testFuzz_amount0ToAmount1_monotonic(uint128 amount, uint128 delta) public pure {
        vm.assume(uint256(amount) + delta <= type(uint128).max);
        assertLe(
            TWAPMath.amount0ToAmount1(amount, SQRT_PRICE_2_1), TWAPMath.amount0ToAmount1(amount + delta, SQRT_PRICE_2_1)
        );
    }

    // --- Matching ---

    function test_matchAmounts_onlyCurrency0() public pure {
        TWAPMath.Match memory result = TWAPMath.matchAmounts(5e18, 0, SQRT_PRICE_2_1);

        assertEq(result.matched0, 0);
        assertEq(result.matched1, 0);
        assertEq(result.excess0, 5e18);
        assertEq(result.excess1, 0);
    }

    function test_matchAmounts_onlyCurrency1() public pure {
        TWAPMath.Match memory result = TWAPMath.matchAmounts(0, 5e18, SQRT_PRICE_2_1);

        assertEq(result.matched0, 0);
        assertEq(result.matched1, 0);
        assertEq(result.excess0, 0);
        assertEq(result.excess1, 5e18);
    }

    function test_matchAmounts_nothingSold() public pure {
        TWAPMath.Match memory result = TWAPMath.matchAmounts(0, 0, SQRT_PRICE_1_1);

        assertEq(result.matched0 + result.matched1 + result.excess0 + result.excess1, 0);
    }

    function test_matchAmounts_equalValue() public pure {
        TWAPMath.Match memory result = TWAPMath.matchAmounts(3e18, 3e18, SQRT_PRICE_1_1);

        assertEq(result.matched0, 3e18);
        assertEq(result.matched1, 3e18);
        assertEq(result.excess0, 0);
        assertEq(result.excess1, 0);
    }

    function test_matchAmounts_excessCurrency0() public pure {
        TWAPMath.Match memory result = TWAPMath.matchAmounts(5e18, 2e18, SQRT_PRICE_1_1);

        assertEq(result.matched0, 2e18);
        assertEq(result.matched1, 2e18);
        assertEq(result.excess0, 3e18);
        assertEq(result.excess1, 0);
    }

    function test_matchAmounts_excessCurrency1() public pure {
        // 1 currency0 is worth 2 currency1, so 5 currency1 cover the whole currency0 side
        TWAPMath.Match memory result = TWAPMath.matchAmounts(1e18, 5e18, SQRT_PRICE_2_1);

        assertEq(result.matched0, 1e18);
        assertApproxEqAbs(result.matched1, 2e18, 10);
        assertApproxEqAbs(result.excess1, 3e18, 10);
        assertEq(result.excess0, 0);
        assertEq(result.matched1 + result.excess1, 5e18);
    }

    function testFuzz_matchAmounts_conservesAmountsAtParity(uint128 amount0, uint128 amount1) public pure {
        TWAPMath.Match memory result = TWAPMath.matchAmounts(amount0, amount1, SQRT_PRICE_1_1);

        assertEq(result.matched0 + result.excess0, amount0);
        assertEq(result.matched1 + result.excess1, amount1);
        assertTrue(result.excess0 == 0 || result.excess1 == 0);
    }

    function testFuzz_matchAmounts_excessCurrency1(uint96 amount0, uint96 amount1) public pure {
        vm.assume(TWAPMath.amount0ToAmount1(amount0, SQRT_PRICE_4_1) < amount1);
        TWAPMath.Match memory result = TWAPMath.matchAmounts(amount0, amount1, SQRT_PRICE_4_1);

        assertEq(result.matched0, amount0);
        assertEq(result.excess0, 0);
        assertEq(result.matched1 + result.excess1, amount1);
    }

    // --- Earnings ---

    function test_earningsFactorIncrement() public pure {
        assertEq(TWAPMath.earningsFactorIncrement(3e18, 1e18), 3 * FixedPoint96.Q96);
        assertEq(TWAPMath.earningsFactorIncrement(0, 1e18), 0);
    }

    function test_earningsBetween() public pure {
        assertEq(TWAPMath.earningsBetween(2e18, FixedPoint96.Q96, 4 * FixedPoint96.Q96), 6e18);
        assertEq(TWAPMath.earningsBetween(2e18, FixedPoint96.Q96, FixedPoint96.Q96), 0);
    }

    function testFuzz_earnings_neverExceedTotal(uint96 earnings, uint96 sellRateA, uint96 sellRateB) public pure {
        vm.assume(sellRateA > 0 && sellRateB > 0);
        uint256 increment = TWAPMath.earningsFactorIncrement(earnings, uint256(sellRateA) + sellRateB);

        uint256 earningsA = TWAPMath.earningsBetween(sellRateA, 0, increment);
        uint256 earningsB = TWAPMath.earningsBetween(sellRateB, 0, increment);
        assertLe(earningsA + earningsB, earnings);
    }

    // --- Epochs ---

    function test_epochAt() public pure {
        assertEq(TWAPMath.epochAt(0, 3600), 0);
        assertEq(TWAPMath.epochAt(3599, 3600), 0);
        assertEq(TWAPMath.epochAt(3600, 3600), 1);
        assertEq(TWAPMath.epochAt(1_800_000_000, 3600), 500_000);
    }
}
