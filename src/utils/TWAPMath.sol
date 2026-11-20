// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/utils/TWAPMath.sol)

pragma solidity ^0.8.24;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/**
 * @dev Library with the math used by time-weighted average price (TWAP) order hooks, such as {TWAPOrderHook}.
 *
 * TWAP orders sell a fixed amount of a currency per epoch. When orders selling `currency0` and orders selling
 * `currency1` are active in the same pool, the amounts sold in an epoch are first matched against each other at the
 * pool price, and only the unmatched part (the "excess") is swapped through the pool. Matching reduces the price
 * impact of the orders and the swap fees they pay.
 *
 * Prices are expressed as `sqrtPriceX96`, the square root of the amount of `currency1` per unit of `currency0`
 * in Q64.96 format, as returned by the `PoolManager`.
 *
 * _Available since v1.2.0_
 */
library TWAPMath {
    /**
     * @dev Result of matching the amounts sold by both sides of a pool in an execution.
     *
     * Only one of `excess0` and `excess1` can be non-zero.
     *
     * @param matched0 Amount of `currency0` given to the orders selling `currency1`, without going through the pool.
     * @param matched1 Amount of `currency1` given to the orders selling `currency0`, without going through the pool.
     * @param excess0 Amount of `currency0` left to be sold through the pool.
     * @param excess1 Amount of `currency1` left to be sold through the pool.
     */
    struct Match {
        uint256 matched0;
        uint256 matched1;
        uint256 excess0;
        uint256 excess1;
    }

    /**
     * @dev Earnings factors are stored as Q128.96 fixed point numbers.
     */
    uint256 internal constant EARNINGS_FACTOR_PRECISION = FixedPoint96.Q96;

    /**
     * @dev Converts an `amount0` of `currency0` into the equivalent amount of `currency1` at `sqrtPriceX96`.
     * Rounds down.
     */
    function amount0ToAmount1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // amount1 = amount0 * price = amount0 * sqrtPrice^2 / 2^192
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /**
     * @dev Converts an `amount1` of `currency1` into the equivalent amount of `currency0` at `sqrtPriceX96`.
     * Rounds down.
     */
    function amount1ToAmount0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // amount0 = amount1 / price = amount1 * 2^192 / sqrtPrice^2
        return FullMath.mulDiv(FullMath.mulDiv(amount1, sqrtPriceX96, FixedPoint96.Q96), FixedPoint96.Q96, sqrtPriceX96);
    }

    /**
     * @dev Matches `amount0` of `currency0` sold by one side of the pool against `amount1` of `currency1` sold by the
     * other side, at `sqrtPriceX96`. The side selling the larger value is partially matched, and its unmatched amount
     * is returned as excess to be swapped through the pool.
     *
     * Matched amounts are rounded down, so the side with the excess never gives more than it sells.
     */
    function matchAmounts(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96)
        internal
        pure
        returns (Match memory result)
    {
        if (amount0ToAmount1(amount0, sqrtPriceX96) >= amount1) {
            // The orders selling `currency1` are fully matched, the rest of `currency0` is swapped
            result.matched1 = amount1;
            result.matched0 = amount1ToAmount0(amount1, sqrtPriceX96);
            result.excess0 = amount0 - result.matched0;
        } else {
            // The orders selling `currency0` are fully matched, the rest of `currency1` is swapped
            result.matched0 = amount0;
            result.matched1 = amount0ToAmount1(amount0, sqrtPriceX96);
            result.excess1 = amount1 - result.matched1;
        }
    }

    /**
     * @dev Returns the increment of the earnings factor of an order pool that sold at `sellRate` per epoch and
     * earned `earnings` in exchange. The earnings factor tracks the earnings per unit of sell rate, so that an order
     * with sell rate `r` earns `r * (factorEnd - factorStart)`.
     */
    function earningsFactorIncrement(uint256 earnings, uint256 sellRate) internal pure returns (uint256) {
        return FullMath.mulDiv(earnings, EARNINGS_FACTOR_PRECISION, sellRate);
    }

    /**
     * @dev Returns the earnings of an order with `sellRate` between the earnings factors `factorStart` and
     * `factorEnd`. Rounds down.
     */
    function earningsBetween(uint256 sellRate, uint256 factorStart, uint256 factorEnd)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(sellRate, factorEnd - factorStart, EARNINGS_FACTOR_PRECISION);
    }

    /**
     * @dev Returns the epoch that contains `timestamp`, for epochs of `epochLength` seconds starting at the Unix epoch.
     */
    function epochAt(uint256 timestamp, uint32 epochLength) internal pure returns (uint32) {
        return uint32(timestamp / epochLength);
    }
}
