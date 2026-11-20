// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/general/TWAPOrderHook.sol)

pragma solidity ^0.8.24;

// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {TWAPMath} from "../utils/TWAPMath.sol";

// External imports
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

/**
 * @dev This hook implements time-weighted average price (TWAP) orders. A TWAP order sells an amount of one of the
 * currencies of the pool in equal parts over a number of epochs, which reduces the price impact of large orders and
 * averages the execution price over time.
 *
 * Time is divided into epochs of `epochLength` seconds. An order submitted during epoch `e` with expiry `x` sells
 * `amountIn / (x - e)` per epoch (its sell rate) in epochs `e` to `x - 1`. Epochs are executed once they are over,
 * by the first swap in the pool after them (through the `beforeSwap` hook) or by anyone calling {executeOrders}.
 *
 * In each execution, the amounts sold by orders selling `currency0` and orders selling `currency1` are matched against
 * each other at the pool price, and only the excess is swapped through the pool (see {TWAPMath-matchAmounts}).
 * The earnings of each side are shared among its orders pro rata to their sell rates, using an earnings factor per
 * order pool, so that executing an epoch costs the same regardless of the number of orders.
 *
 * Earnings are credited to the owner of an order when it is cancelled or claimed through {claimEarnings}, and can be
 * withdrawn with {claimTokens}. Owners can approve operators to cancel orders on their behalf. A protocol fee, set by
 * the owner of the hook, can be taken from the earnings.
 *
 * NOTE: Orders are executed at the pool price at the time of execution, without a price limit. TWAP orders are meant
 * for pools with enough liquidity for the amounts sold per epoch. See the TWAP orders page of the documentation for
 * the considerations to take into account when deploying this hook.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v1.2.0_
 */
contract TWAPOrderHook is BaseHook, IUnlockCallback, Ownable {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /**
     * @dev Identifies an order of a pool.
     *
     * @param owner The owner of the order, who receives its earnings and its refund.
     * @param expiry The epoch at which the order stops selling. The last epoch sold is `expiry - 1`.
     * @param zeroForOne Whether the order sells `currency0` for `currency1`.
     */
    struct OrderKey {
        address owner;
        uint32 expiry;
        bool zeroForOne;
    }

    /**
     * @dev State of an order.
     *
     * @param sellRate The amount sold by the order in each epoch.
     * @param earningsFactorLast The earnings factor of the order pool when the earnings of the order were last
     * credited.
     */
    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    /**
     * @dev State of the orders selling one of the currencies of a pool.
     *
     * @param sellRateCurrent The sum of the sell rates of the active orders.
     * @param earningsFactorCurrent The accumulated earnings per unit of sell rate, as a Q128.96 fixed point number.
     * @param sellRateEndingAtEpoch The sum of the sell rates of the orders that expire at each epoch.
     * @param earningsFactorAtEpoch The earnings factor at each epoch at which orders expire.
     */
    struct OrderPool {
        uint256 sellRateCurrent;
        uint256 earningsFactorCurrent;
        mapping(uint32 epoch => uint256) sellRateEndingAtEpoch;
        mapping(uint32 epoch => uint256) earningsFactorAtEpoch;
    }

    /**
     * @dev State of a pool.
     *
     * @param initialized Whether the pool has been initialized with this hook.
     * @param nextEpochToExecute The first epoch that has not been executed yet.
     * @param orderPool0For1 The orders selling `currency0` for `currency1`.
     * @param orderPool1For0 The orders selling `currency1` for `currency0`.
     * @param orders The orders of the pool, by order id.
     */
    struct PoolState {
        bool initialized;
        uint32 nextEpochToExecute;
        OrderPool orderPool0For1;
        OrderPool orderPool1For0;
        mapping(bytes32 orderId => Order) orders;
    }

    /**
     * @dev The denominator of the protocol fee, in basis points.
     */
    uint256 public constant PROTOCOL_FEE_DENOMINATOR = 10_000;

    /**
     * @dev The maximum protocol fee, 10% of the earnings.
     */
    uint256 public constant MAX_PROTOCOL_FEE = 1_000;

    /**
     * @dev The zero bytes.
     */
    bytes internal constant ZERO_BYTES = bytes("");

    /**
     * @dev The length of an epoch, in seconds.
     */
    uint32 public immutable epochLength;

    /**
     * @dev The protocol fee taken from the earnings of the orders, in basis points.
     */
    uint256 public protocolFee;

    /**
     * @dev The protocol fees accrued and not collected yet, per currency.
     */
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;

    /**
     * @dev The tokens credited to each owner and not claimed yet, per currency.
     */
    mapping(Currency currency => mapping(address owner => uint256 amount)) public tokensOwed;

    /**
     * @dev Whether an operator is approved by an owner to cancel the orders of the owner.
     */
    mapping(address owner => mapping(address operator => bool approved)) public isOperator;

    /**
     * @dev The state of each pool.
     */
    mapping(PoolId poolId => PoolState) internal _poolStates;

    /**
     * @dev The epoch length is zero.
     */
    error InvalidEpochLength();

    /**
     * @dev The pool has not been initialized with this hook.
     */
    error PoolNotInitialized();

    /**
     * @dev The expiry of the order is not after the current epoch.
     */
    error InvalidExpiry();

    /**
     * @dev The amount of the order is too low to sell a non-zero amount per epoch.
     */
    error SellRateTooLow();

    /**
     * @dev The native amount sent does not match the amount of the order.
     */
    error InvalidNativeAmount();

    /**
     * @dev The order does not exist.
     */
    error OrderNotFound();

    /**
     * @dev The order has already expired.
     */
    error OrderExpired();

    /**
     * @dev The caller is neither the owner of the order nor an approved operator.
     */
    error Unauthorized();

    /**
     * @dev The amount claimed is greater than the amount owed.
     */
    error InsufficientTokensOwed();

    /**
     * @dev The protocol fee is greater than {MAX_PROTOCOL_FEE}.
     */
    error ProtocolFeeTooHigh();

    /**
     * @dev Emitted when an order is submitted or topped up.
     */
    event OrderSubmitted(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        address indexed owner,
        uint32 expiry,
        bool zeroForOne,
        uint256 sellRate,
        uint256 amountIn
    );

    /**
     * @dev Emitted when an order is cancelled.
     */
    event OrderCancelled(
        PoolId indexed poolId, bytes32 indexed orderId, address indexed owner, uint256 refund, uint256 earnings
    );

    /**
     * @dev Emitted when the earnings of an order are credited to its owner through {claimEarnings}.
     */
    event EarningsClaimed(PoolId indexed poolId, bytes32 indexed orderId, address indexed owner, uint256 earnings);

    /**
     * @dev Emitted when the epochs `fromEpoch` to `toEpoch - 1` of a pool are executed.
     */
    event OrdersExecuted(PoolId indexed poolId, uint32 fromEpoch, uint32 toEpoch);

    /**
     * @dev Emitted when an owner withdraws tokens credited to it.
     */
    event TokensClaimed(Currency indexed currency, address indexed owner, address to, uint256 amount);

    /**
     * @dev Emitted when an owner approves or revokes an operator.
     */
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Emitted when the protocol fee is updated.
     */
    event ProtocolFeeSet(uint256 protocolFee);

    /**
     * @dev Emitted when protocol fees are collected.
     */
    event ProtocolFeesCollected(Currency indexed currency, address to, uint256 amount);

    /**
     * @dev Set the `PoolManager` address, the epoch length and the initial owner of the hook.
     */
    constructor(IPoolManager _poolManager, uint32 _epochLength, address initialOwner)
        BaseHook(_poolManager)
        Ownable(initialOwner)
    {
        if (_epochLength == 0) revert InvalidEpochLength();
        epochLength = _epochLength;
    }

    /**
     * @dev Receive the native currency taken from the `PoolManager` when orders are executed.
     */
    receive() external payable onlyPoolManager {}

    /**
     * @dev Hooks into the `afterInitialize` hook to start executing orders from the current epoch.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        PoolState storage state = _poolStates[key.toId()];
        state.initialized = true;
        state.nextEpochToExecute = currentEpoch();

        return this.afterInitialize.selector;
    }

    /**
     * @dev Hooks into the `beforeSwap` hook to execute the epochs that are over before the swap.
     *
     * NOTE: The swaps of the hook itself do not trigger this hook, given that the `PoolManager` does not call hooks
     * on their own swaps.
     */
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _executeOrders(key);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Submits an order selling `amountIn` of `currency0` (if `zeroForOne`) or `currency1` of the pool `key`
     * evenly from the current epoch until `expiry`. If the caller already has an order with the same expiry and
     * direction, the order is topped up instead. Returns the id of the order and the sell rate added.
     *
     * For native currency orders, `amountIn` must be sent as value. For ERC-20 orders, the hook must be approved to
     * transfer `amountIn`.
     */
    function submitOrder(PoolKey calldata key, bool zeroForOne, uint32 expiry, uint256 amountIn)
        external
        payable
        virtual
        returns (bytes32 orderId, uint256 sellRate)
    {
        PoolState storage state = _poolStates[key.toId()];
        if (!state.initialized) revert PoolNotInitialized();

        // Execute the epochs that are over, so that the order does not take part in them
        _executeOrdersUnlocked(key);

        uint32 epoch = currentEpoch();
        if (expiry <= epoch) revert InvalidExpiry();

        // The amount is sold evenly in the epochs from the current one until `expiry`, rounded down
        sellRate = amountIn / (expiry - epoch);
        if (sellRate == 0) revert SellRateTooLow();

        OrderKey memory orderKey = OrderKey({owner: msg.sender, expiry: expiry, zeroForOne: zeroForOne});
        orderId = getOrderId(orderKey);

        OrderPool storage orderPool = _getOrderPool(state, zeroForOne);
        Order storage order = state.orders[orderId];

        // New orders start earning from the current earnings factor
        if (order.sellRate == 0) order.earningsFactorLast = orderPool.earningsFactorCurrent;

        order.sellRate += sellRate;
        orderPool.sellRateCurrent += sellRate;
        orderPool.sellRateEndingAtEpoch[expiry] += sellRate;

        // Credit the earnings accrued by the order so far, if it is topped up, and move it to the current
        // earnings factor. This is a no-op for new orders.
        _accrueEarnings(key, orderKey, order, orderPool, epoch);

        _pay(zeroForOne ? key.currency0 : key.currency1, amountIn);

        emit OrderSubmitted(key.toId(), orderId, msg.sender, expiry, zeroForOne, sellRate, amountIn);
    }

    /**
     * @dev Cancels the order `orderKey` of the pool `key`. The amount not sold yet is refunded to `to`, and the
     * earnings of the order are credited to its owner. Can be called by the owner of the order or by an operator
     * approved by the owner. Returns the amount refunded and the earnings credited.
     */
    function cancelOrder(PoolKey calldata key, OrderKey calldata orderKey, address to)
        external
        virtual
        returns (uint256 refund, uint256 earnings)
    {
        _checkAuthorized(orderKey.owner);

        // Execute the epochs that are over, so that the order is credited for them
        _executeOrdersUnlocked(key);

        uint32 epoch = currentEpoch();

        // The order can be cancelled until its last epoch has been executed
        if (orderKey.expiry < epoch) revert OrderExpired();

        PoolState storage state = _poolStates[key.toId()];
        bytes32 orderId = getOrderId(orderKey);
        Order storage order = state.orders[orderId];

        uint256 sellRate = order.sellRate;
        if (sellRate == 0) revert OrderNotFound();

        OrderPool storage orderPool = _getOrderPool(state, orderKey.zeroForOne);
        earnings = _accrueEarnings(key, orderKey, order, orderPool, epoch);

        // The current epoch has not been executed yet, so it is refunded as well
        refund = sellRate * (orderKey.expiry - epoch);

        orderPool.sellRateCurrent -= sellRate;
        orderPool.sellRateEndingAtEpoch[orderKey.expiry] -= sellRate;
        delete state.orders[orderId];

        if (refund > 0) (orderKey.zeroForOne ? key.currency0 : key.currency1).transfer(to, refund);

        emit OrderCancelled(key.toId(), orderId, orderKey.owner, refund, earnings);
    }

    /**
     * @dev Credits the earnings of the order `orderKey` of the pool `key` to its owner, and deletes the order if it
     * has expired. Can be called by anyone. Returns the earnings credited.
     */
    function claimEarnings(PoolKey calldata key, OrderKey calldata orderKey)
        external
        virtual
        returns (uint256 earnings)
    {
        _executeOrdersUnlocked(key);

        PoolState storage state = _poolStates[key.toId()];
        bytes32 orderId = getOrderId(orderKey);
        Order storage order = state.orders[orderId];
        if (order.sellRate == 0) revert OrderNotFound();

        uint32 nextEpoch = state.nextEpochToExecute;
        earnings = _accrueEarnings(key, orderKey, order, _getOrderPool(state, orderKey.zeroForOne), nextEpoch);

        // Expired orders have nothing left to earn
        if (orderKey.expiry <= nextEpoch) delete state.orders[orderId];

        emit EarningsClaimed(key.toId(), orderId, orderKey.owner, earnings);
    }

    /**
     * @dev Withdraws `amount` of `currency` credited to the caller, sending it to `to`. An `amount` of zero withdraws
     * everything credited. Returns the amount withdrawn.
     */
    function claimTokens(Currency currency, address to, uint256 amount) external virtual returns (uint256) {
        uint256 owed = tokensOwed[currency][msg.sender];
        if (amount == 0) amount = owed;
        if (amount > owed) revert InsufficientTokensOwed();

        tokensOwed[currency][msg.sender] = owed - amount;
        currency.transfer(to, amount);

        emit TokensClaimed(currency, msg.sender, to, amount);
        return amount;
    }

    /**
     * @dev Approves or revokes `operator` to cancel the orders of the caller.
     */
    function setOperator(address operator, bool approved) external virtual {
        isOperator[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);
    }

    /**
     * @dev Executes the epochs of the pool `key` that are over. Can be called by anyone, for example to execute
     * orders in pools that are not swapped often.
     */
    function executeOrders(PoolKey calldata key) external virtual {
        if (!_poolStates[key.toId()].initialized) revert PoolNotInitialized();

        _executeOrdersUnlocked(key);
    }

    /**
     * @dev Sets the protocol fee taken from the earnings of the orders to `newProtocolFee` basis points. Only
     * callable by the owner of the hook.
     */
    function setProtocolFee(uint256 newProtocolFee) external virtual onlyOwner {
        if (newProtocolFee > MAX_PROTOCOL_FEE) revert ProtocolFeeTooHigh();
        protocolFee = newProtocolFee;

        emit ProtocolFeeSet(newProtocolFee);
    }

    /**
     * @dev Sends the protocol fees accrued in `currency` to `to`. Only callable by the owner of the hook.
     */
    function collectProtocolFees(Currency currency, address to) external virtual onlyOwner returns (uint256 amount) {
        amount = protocolFeesAccrued[currency];
        protocolFeesAccrued[currency] = 0;
        currency.transfer(to, amount);

        emit ProtocolFeesCollected(currency, to, amount);
    }

    /**
     * @dev Handles the callback from the `PoolManager` started by {_executeOrdersUnlocked}. Executes the epochs of the
     * pool encoded in `rawData` that are over. Only callable by the `PoolManager`.
     */
    function unlockCallback(bytes calldata rawData) external virtual override onlyPoolManager returns (bytes memory) {
        PoolKey memory key = abi.decode(rawData, (PoolKey));
        _executeOrders(key);

        return ZERO_BYTES;
    }

    /**
     * @dev Unlocks the `PoolManager` to execute the epochs of the pool `key` that are over, if any.
     */
    function _executeOrdersUnlocked(PoolKey memory key) internal virtual {
        PoolState storage state = _poolStates[key.toId()];
        if (state.initialized && state.nextEpochToExecute < currentEpoch()) {
            poolManager.unlock(abi.encode(key));
        }
    }

    /**
     * @dev Executes the epochs of the pool `key` from `nextEpochToExecute` to the current epoch (exclusive). Must be
     * called while the `PoolManager` is unlocked.
     *
     * Sell rates only change when orders expire (submissions and cancellations always execute the pool first), so the
     * epochs between two expirations are executed together as a single batch.
     */
    function _executeOrders(PoolKey memory key) internal virtual {
        PoolState storage state = _poolStates[key.toId()];
        uint32 epoch = currentEpoch();
        uint32 fromEpoch = state.nextEpochToExecute;
        if (!state.initialized || fromEpoch >= epoch) return;

        // Updated before executing, so that a nested call (for example from a swap triggered by a token transfer)
        // does not execute the same epochs again
        state.nextEpochToExecute = epoch;

        OrderPool storage orderPool0For1 = state.orderPool0For1;
        OrderPool storage orderPool1For0 = state.orderPool1For0;

        uint32 batchStart = fromEpoch;
        for (uint32 boundary = fromEpoch + 1; boundary <= epoch; ++boundary) {
            uint256 ending0For1 = orderPool0For1.sellRateEndingAtEpoch[boundary];
            uint256 ending1For0 = orderPool1For0.sellRateEndingAtEpoch[boundary];
            if (ending0For1 == 0 && ending1For0 == 0 && boundary != epoch) continue;

            _executeBatch(key, orderPool0For1, orderPool1For0, boundary - batchStart);

            // The orders expiring at `boundary` stop selling from this epoch on
            orderPool0For1.sellRateCurrent -= ending0For1;
            orderPool1For0.sellRateCurrent -= ending1For0;
            orderPool0For1.earningsFactorAtEpoch[boundary] = orderPool0For1.earningsFactorCurrent;
            orderPool1For0.earningsFactorAtEpoch[boundary] = orderPool1For0.earningsFactorCurrent;

            batchStart = boundary;
        }

        emit OrdersExecuted(key.toId(), fromEpoch, epoch);
    }

    /**
     * @dev Executes `numEpochs` epochs of both order pools of the pool `key` at the current sell rates. The amounts
     * sold by both sides are matched against each other at the pool price, the excess is swapped through the pool,
     * and the earnings of each side are added to its earnings factor.
     */
    function _executeBatch(
        PoolKey memory key,
        OrderPool storage orderPool0For1,
        OrderPool storage orderPool1For0,
        uint256 numEpochs
    ) internal virtual {
        uint256 sellRate0For1 = orderPool0For1.sellRateCurrent;
        uint256 sellRate1For0 = orderPool1For0.sellRateCurrent;
        if (sellRate0For1 == 0 && sellRate1For0 == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        TWAPMath.Match memory result =
            TWAPMath.matchAmounts(sellRate0For1 * numEpochs, sellRate1For0 * numEpochs, sqrtPriceX96);

        // `earnings0` is earned by the orders selling `currency1`, and `earnings1` by the orders selling `currency0`
        uint256 earnings0 = result.matched0;
        uint256 earnings1 = result.matched1;
        if (result.excess0 > 0) {
            earnings1 += _swapExcess(key, true, result.excess0);
        } else if (result.excess1 > 0) {
            earnings0 += _swapExcess(key, false, result.excess1);
        }

        // Protocol fees are taken from the earnings before they are distributed to the orders
        if (sellRate0For1 > 0) {
            _accrueProtocolFee(key.currency1, earnings1);
            orderPool0For1.earningsFactorCurrent += TWAPMath.earningsFactorIncrement(earnings1, sellRate0For1);
        }
        if (sellRate1For0 > 0) {
            _accrueProtocolFee(key.currency0, earnings0);
            orderPool1For0.earningsFactorCurrent += TWAPMath.earningsFactorIncrement(earnings0, sellRate1For0);
        }
    }

    /**
     * @dev Swaps `amountIn` of `currency0` (if `zeroForOne`) or `currency1` through the pool `key` and settles the
     * resulting deltas with the `PoolManager`. Returns the amount received.
     */
    function _swapExcess(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        virtual
        returns (uint256 amountOut)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ZERO_BYTES
        );

        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 amountSpecified, int128 amountUnspecified) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        // Exact input swap: the input is owed to the `PoolManager` and the output is owed to the hook
        currencyIn.settle(poolManager, address(this), uint256(uint128(-amountSpecified)), false);
        amountOut = uint256(uint128(amountUnspecified));
        currencyOut.take(poolManager, address(this), amountOut, false);
    }

    /**
     * @dev Credits the earnings of `order` since it was last credited to the owner in `orderKey`. For expired orders,
     * earnings are counted until the expiry of the order. `nextEpochToExecute` is the first epoch of the pool `key`
     * that has not been executed yet. Returns the earnings credited.
     */
    function _accrueEarnings(
        PoolKey memory key,
        OrderKey memory orderKey,
        Order storage order,
        OrderPool storage orderPool,
        uint32 nextEpochToExecute
    ) internal virtual returns (uint256 earnings) {
        uint256 earningsFactor = orderKey.expiry <= nextEpochToExecute
            ? orderPool.earningsFactorAtEpoch[orderKey.expiry]
            : orderPool.earningsFactorCurrent;

        earnings = TWAPMath.earningsBetween(order.sellRate, order.earningsFactorLast, earningsFactor);
        order.earningsFactorLast = earningsFactor;

        if (earnings > 0) {
            Currency currencyOut = orderKey.zeroForOne ? key.currency1 : key.currency0;
            tokensOwed[currencyOut][orderKey.owner] += earnings;
        }
    }

    /**
     * @dev Accrues the protocol fee on `earnings` of `currency`.
     */
    function _accrueProtocolFee(Currency currency, uint256 earnings) internal virtual {
        uint256 fee = protocolFee;
        if (fee == 0) return;

        protocolFeesAccrued[currency] += earnings * fee / PROTOCOL_FEE_DENOMINATOR;
    }

    /**
     * @dev Transfers `amount` of `currency` from the caller to the hook. For the native currency, `amount` must be
     * sent as value.
     */
    function _pay(Currency currency, uint256 amount) internal virtual {
        if (currency.isAddressZero()) {
            if (msg.value != amount) revert InvalidNativeAmount();
        } else {
            if (msg.value != 0) revert InvalidNativeAmount();
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    /**
     * @dev Reverts if the caller is neither `owner` nor an operator approved by `owner`.
     */
    function _checkAuthorized(address owner) internal view virtual {
        if (msg.sender != owner && !isOperator[msg.sender][owner]) revert Unauthorized();
    }

    /**
     * @dev Returns the order pool of `state` selling `currency0` (if `zeroForOne`) or `currency1`.
     */
    function _getOrderPool(PoolState storage state, bool zeroForOne) internal view returns (OrderPool storage) {
        return zeroForOne ? state.orderPool0For1 : state.orderPool1For0;
    }

    /**
     * @dev Returns the current epoch.
     */
    function currentEpoch() public view virtual returns (uint32) {
        return TWAPMath.epochAt(block.timestamp, epochLength);
    }

    /**
     * @dev Returns the id of the order `orderKey`.
     */
    function getOrderId(OrderKey memory orderKey) public pure returns (bytes32) {
        return keccak256(abi.encode(orderKey));
    }

    /**
     * @dev Returns the order `orderKey` of the pool `key`.
     */
    function getOrder(PoolKey calldata key, OrderKey calldata orderKey) external view returns (Order memory) {
        return _poolStates[key.toId()].orders[getOrderId(orderKey)];
    }

    /**
     * @dev Returns the first epoch of the pool `key` that has not been executed yet.
     */
    function getNextEpochToExecute(PoolKey calldata key) external view returns (uint32) {
        return _poolStates[key.toId()].nextEpochToExecute;
    }

    /**
     * @dev Returns the current sell rate and earnings factor of the orders of the pool `key` selling `currency0`
     * (if `zeroForOne`) or `currency1`.
     */
    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
    {
        OrderPool storage orderPool = _getOrderPool(_poolStates[key.toId()], zeroForOne);
        return (orderPool.sellRateCurrent, orderPool.earningsFactorCurrent);
    }

    /**
     * @dev Returns the sum of the sell rates of the orders of the pool `key` selling `currency0` (if `zeroForOne`)
     * or `currency1` that expire at `epoch`.
     */
    function getSellRateEndingAtEpoch(PoolKey calldata key, bool zeroForOne, uint32 epoch)
        external
        view
        returns (uint256)
    {
        return _getOrderPool(_poolStates[key.toId()], zeroForOne).sellRateEndingAtEpoch[epoch];
    }

    /**
     * @dev Returns the earnings factor at `epoch` of the orders of the pool `key` selling `currency0` (if
     * `zeroForOne`) or `currency1`. Only recorded for executed epochs at which orders expire.
     */
    function getEarningsFactorAtEpoch(PoolKey calldata key, bool zeroForOne, uint32 epoch)
        external
        view
        returns (uint256)
    {
        return _getOrderPool(_poolStates[key.toId()], zeroForOne).earningsFactorAtEpoch[epoch];
    }

    /**
     * @dev Set the hooks permissions, specifically `afterInitialize` and `beforeSwap`.
     *
     * @return permissions The permissions for the hook.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
