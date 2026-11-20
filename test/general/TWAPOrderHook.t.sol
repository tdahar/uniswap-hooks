// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {BaseHook} from "src/base/BaseHook.sol";
import {TWAPOrderHook} from "src/general/TWAPOrderHook.sol";

contract TWAPOrderHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint32 constant EPOCH_LENGTH = 1 hours;
    uint256 constant FULL_RANGE_LIQUIDITY = 10_000e18;

    TWAPOrderHook hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event OrderSubmitted(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        address indexed owner,
        uint32 expiry,
        bool zeroForOne,
        uint256 sellRate,
        uint256 amountIn
    );
    event OrdersExecuted(PoolId indexed poolId, uint32 fromEpoch, uint32 toEpoch);
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    function setUp() public {
        // Start at the beginning of an epoch, at a realistic timestamp
        vm.warp(uint256(EPOCH_LENGTH) * 500_000);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = TWAPOrderHook(payable(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG))));
        deployCodeTo(
            "src/general/TWAPOrderHook.sol:TWAPOrderHook",
            abi.encode(manager, EPOCH_LENGTH, address(this)),
            address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(key, FULL_RANGE_LIQUIDITY, 0);

        _fundAndApprove(alice);
        _fundAndApprove(bob);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
        vm.label(address(hook), "hook");
    }

    // --- Setup and permissions ---

    function test_deployment() public view {
        assertEq(hook.epochLength(), EPOCH_LENGTH);
        assertEq(hook.owner(), address(this));
        assertEq(hook.protocolFee(), 0);
        assertEq(hook.currentEpoch(), 500_000);
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeSwap);
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterSwap);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
    }

    function test_afterInitialize_setsNextEpochToExecute() public view {
        assertEq(hook.getNextEpochToExecute(key), hook.currentEpoch());
    }

    function test_afterInitialize_onlyPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_receive_onlyPoolManager() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertFalse(success);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(key));
    }

    // --- Submitting orders ---

    function test_submitOrder() public {
        uint32 expiry = hook.currentEpoch() + 10;
        uint256 balanceBefore = currency0.balanceOf(alice);

        TWAPOrderHook.OrderKey memory orderKey =
            TWAPOrderHook.OrderKey({owner: alice, expiry: expiry, zeroForOne: true});
        bytes32 expectedOrderId = hook.getOrderId(orderKey);

        vm.expectEmit(address(hook));
        emit OrderSubmitted(key.toId(), expectedOrderId, alice, expiry, true, 1e18, 10e18);

        vm.prank(alice);
        (bytes32 orderId, uint256 sellRate) = hook.submitOrder(key, true, expiry, 10e18);

        assertEq(orderId, expectedOrderId);
        assertEq(sellRate, 1e18);
        assertEq(balanceBefore - currency0.balanceOf(alice), 10e18);
        assertEq(currency0.balanceOf(address(hook)), 10e18);

        TWAPOrderHook.Order memory order = hook.getOrder(key, orderKey);
        assertEq(order.sellRate, 1e18);
        assertEq(order.earningsFactorLast, 0);

        (uint256 sellRateCurrent, uint256 earningsFactorCurrent) = hook.getOrderPool(key, true);
        assertEq(sellRateCurrent, 1e18);
        assertEq(earningsFactorCurrent, 0);
        assertEq(hook.getSellRateEndingAtEpoch(key, true, expiry), 1e18);

        (sellRateCurrent,) = hook.getOrderPool(key, false);
        assertEq(sellRateCurrent, 0);
    }

    function test_submitOrder_oneForZero() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(bob, false, 4, 8e18);

        assertEq(hook.getOrder(key, orderKey).sellRate, 2e18);
        assertEq(currency1.balanceOf(address(hook)), 8e18);

        (uint256 sellRateCurrent,) = hook.getOrderPool(key, false);
        assertEq(sellRateCurrent, 2e18);
    }

    function test_submitOrder_topUpInSameEpoch() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 10, 10e18);

        vm.prank(alice);
        hook.submitOrder(key, true, orderKey.expiry, 20e18);

        assertEq(hook.getOrder(key, orderKey).sellRate, 3e18);
        assertEq(hook.getSellRateEndingAtEpoch(key, true, orderKey.expiry), 3e18);
        assertEq(hook.tokensOwed(currency1, alice), 0);
        assertEq(currency0.balanceOf(address(hook)), 30e18);
    }

    function test_submitOrder_differentOwnersSameExpiry() public {
        TWAPOrderHook.OrderKey memory aliceKey = _submit(alice, true, 5, 5e18);
        TWAPOrderHook.OrderKey memory bobKey = _submit(bob, true, 5, 10e18);

        assertTrue(hook.getOrderId(aliceKey) != hook.getOrderId(bobKey));
        assertEq(hook.getSellRateEndingAtEpoch(key, true, aliceKey.expiry), 3e18);
    }

    function test_submitOrder_revertsPoolNotInitialized() public {
        PoolKey memory otherKey = key;
        otherKey.fee = 500;
        otherKey.tickSpacing = 10;

        uint32 expiry = hook.currentEpoch() + 1;

        vm.expectRevert(TWAPOrderHook.PoolNotInitialized.selector);
        vm.prank(alice);
        hook.submitOrder(otherKey, true, expiry, 1e18);
    }

    function test_submitOrder_revertsInvalidExpiry() public {
        uint32 epoch = hook.currentEpoch();

        vm.startPrank(alice);
        vm.expectRevert(TWAPOrderHook.InvalidExpiry.selector);
        hook.submitOrder(key, true, epoch, 1e18);

        vm.expectRevert(TWAPOrderHook.InvalidExpiry.selector);
        hook.submitOrder(key, true, epoch - 1, 1e18);
        vm.stopPrank();
    }

    function test_submitOrder_revertsSellRateTooLow() public {
        uint32 expiry = hook.currentEpoch() + 10;

        vm.expectRevert(TWAPOrderHook.SellRateTooLow.selector);
        vm.prank(alice);
        hook.submitOrder(key, true, expiry, 9);
    }

    function test_submitOrder_revertsNativeValueForERC20() public {
        vm.deal(alice, 1 ether);
        uint32 expiry = hook.currentEpoch() + 1;

        vm.expectRevert(TWAPOrderHook.InvalidNativeAmount.selector);
        vm.prank(alice);
        hook.submitOrder{value: 1 ether}(key, true, expiry, 1e18);
    }

    // --- Executing orders ---

    function test_executeOrders_noOpWithinEpoch() public {
        _submit(alice, true, 10, 10e18);
        uint32 nextEpoch = hook.getNextEpochToExecute(key);

        vm.warp(block.timestamp + EPOCH_LENGTH - 1);
        hook.executeOrders(key);

        assertEq(hook.getNextEpochToExecute(key), nextEpoch);
        assertEq(currency0.balanceOf(address(hook)), 10e18);
    }

    function test_executeOrders_sellsElapsedEpochs() public {
        _submit(alice, true, 10, 10e18);
        uint32 fromEpoch = hook.currentEpoch();

        _warpEpochs(3);

        vm.expectEmit(address(hook));
        emit OrdersExecuted(key.toId(), fromEpoch, fromEpoch + 3);
        hook.executeOrders(key);

        assertEq(hook.getNextEpochToExecute(key), fromEpoch + 3);
        assertEq(currency0.balanceOf(address(hook)), 7e18);

        uint256 earnings = currency1.balanceOf(address(hook));
        assertApproxEqRel(earnings, 3e18, 0.01e18);

        (uint256 sellRateCurrent, uint256 earningsFactorCurrent) = hook.getOrderPool(key, true);
        assertEq(sellRateCurrent, 1e18);
        assertEq(earningsFactorCurrent, earnings * FixedPoint96.Q96 / 1e18);
    }

    function test_executeOrders_movesPoolPrice() public {
        _submit(alice, true, 2, 20e18);
        _warpEpochs(2);
        hook.executeOrders(key);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertLt(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    function test_executeOrders_revertsPoolNotInitialized() public {
        PoolKey memory otherKey = key;
        otherKey.fee = 500;
        otherKey.tickSpacing = 10;

        vm.expectRevert(TWAPOrderHook.PoolNotInitialized.selector);
        hook.executeOrders(otherKey);
    }

    function test_executeOrders_withoutOrders() public {
        uint32 fromEpoch = hook.currentEpoch();
        _warpEpochs(5);
        hook.executeOrders(key);

        assertEq(hook.getNextEpochToExecute(key), fromEpoch + 5);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    function test_beforeSwap_executesOrders() public {
        _submit(alice, true, 10, 10e18);
        uint32 fromEpoch = hook.currentEpoch();

        _warpEpochs(2);
        swap(key, false, -1e15, ZERO_BYTES);

        assertEq(hook.getNextEpochToExecute(key), fromEpoch + 2);
        assertEq(currency0.balanceOf(address(hook)), 8e18);
    }

    function test_beforeSwap_doesNotExecuteWithinEpoch() public {
        _submit(alice, true, 10, 10e18);
        swap(key, true, -1e15, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(hook)), 10e18);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    function test_opposingOrders_matchedWithoutSwap() public {
        TWAPOrderHook.OrderKey memory aliceKey = _submit(alice, true, 10, 10e18);
        TWAPOrderHook.OrderKey memory bobKey = _submit(bob, false, 10, 10e18);

        _warpEpochs(10);
        hook.executeOrders(key);

        // Both sides cancel out at the pool price, so the pool is not touched
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);

        assertEq(hook.claimEarnings(key, aliceKey), 10e18);
        assertEq(hook.claimEarnings(key, bobKey), 10e18);
        assertEq(hook.tokensOwed(currency1, alice), 10e18);
        assertEq(hook.tokensOwed(currency0, bob), 10e18);
    }

    function test_opposingOrders_excessSwapped() public {
        TWAPOrderHook.OrderKey memory aliceKey = _submit(alice, true, 10, 10e18);
        TWAPOrderHook.OrderKey memory bobKey = _submit(bob, false, 10, 4e18);

        _warpEpochs(10);
        hook.executeOrders(key);

        // Bob is fully matched at the pool price, and the excess of alice is swapped through the pool
        assertEq(hook.claimEarnings(key, bobKey), 4e18);

        uint256 aliceEarnings = hook.claimEarnings(key, aliceKey);
        assertGt(aliceEarnings, 4e18);
        assertApproxEqRel(aliceEarnings, 10e18, 0.01e18);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertLt(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    function test_ordersExpiringAtDifferentEpochs() public {
        TWAPOrderHook.OrderKey memory aliceKey = _submit(alice, true, 5, 5e18);
        TWAPOrderHook.OrderKey memory bobKey = _submit(bob, true, 10, 10e18);

        _warpEpochs(12);
        hook.executeOrders(key);

        (uint256 sellRateCurrent,) = hook.getOrderPool(key, true);
        assertEq(sellRateCurrent, 0);
        assertGt(hook.getEarningsFactorAtEpoch(key, true, aliceKey.expiry), 0);
        assertGt(
            hook.getEarningsFactorAtEpoch(key, true, bobKey.expiry),
            hook.getEarningsFactorAtEpoch(key, true, aliceKey.expiry)
        );

        uint256 aliceEarnings = hook.claimEarnings(key, aliceKey);
        uint256 bobEarnings = hook.claimEarnings(key, bobKey);

        assertApproxEqRel(aliceEarnings, 5e18, 0.01e18);
        assertApproxEqRel(bobEarnings, 10e18, 0.01e18);
        // Bob sold half of his order after alice's order expired, at a lower price
        assertLt(bobEarnings, 2 * aliceEarnings);

        // All the currency0 deposited has been sold
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertLe(aliceEarnings + bobEarnings, currency1.balanceOf(address(hook)));
    }

    function test_executeOrders_acrossManyIdleEpochs() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 3, 3e18);

        _warpEpochs(200);
        hook.executeOrders(key);

        assertEq(hook.getNextEpochToExecute(key), orderKey.expiry + 197);
        assertEq(currency0.balanceOf(address(hook)), 0);
    }

    // --- Claiming ---

    function test_claimEarnings_activeOrder() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 10, 10e18);

        _warpEpochs(4);
        uint256 earnings = hook.claimEarnings(key, orderKey);

        assertApproxEqRel(earnings, 4e18, 0.01e18);
        assertEq(hook.tokensOwed(currency1, alice), earnings);

        // The order keeps selling
        TWAPOrderHook.Order memory order = hook.getOrder(key, orderKey);
        assertEq(order.sellRate, 1e18);
        (, uint256 earningsFactorCurrent) = hook.getOrderPool(key, true);
        assertEq(order.earningsFactorLast, earningsFactorCurrent);

        // Claiming again in the same epoch earns nothing
        assertEq(hook.claimEarnings(key, orderKey), 0);
    }

    function test_claimEarnings_expiredOrderIsDeleted() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 10, 10e18);

        _warpEpochs(11);
        uint256 earnings = hook.claimEarnings(key, orderKey);

        assertApproxEqRel(earnings, 10e18, 0.01e18);
        assertEq(hook.getOrder(key, orderKey).sellRate, 0);

        vm.expectRevert(TWAPOrderHook.OrderNotFound.selector);
        hook.claimEarnings(key, orderKey);
    }

    function test_claimEarnings_byAnyoneCreditsOwner() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 2, 2e18);

        _warpEpochs(2);
        vm.prank(bob);
        uint256 earnings = hook.claimEarnings(key, orderKey);

        assertEq(hook.tokensOwed(currency1, alice), earnings);
        assertEq(hook.tokensOwed(currency1, bob), 0);
    }

    function test_claimEarnings_revertsOrderNotFound() public {
        TWAPOrderHook.OrderKey memory orderKey =
            TWAPOrderHook.OrderKey({owner: alice, expiry: hook.currentEpoch() + 1, zeroForOne: true});

        vm.expectRevert(TWAPOrderHook.OrderNotFound.selector);
        hook.claimEarnings(key, orderKey);
    }

    function test_claimTokens() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 2, 2e18);
        _warpEpochs(2);
        uint256 earnings = hook.claimEarnings(key, orderKey);

        uint256 balanceBefore = currency1.balanceOf(bob);
        vm.prank(alice);
        assertEq(hook.claimTokens(currency1, bob, 0), earnings);

        assertEq(currency1.balanceOf(bob) - balanceBefore, earnings);
        assertEq(hook.tokensOwed(currency1, alice), 0);
    }

    function test_claimTokens_partial() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 2, 2e18);
        _warpEpochs(2);
        uint256 earnings = hook.claimEarnings(key, orderKey);

        vm.startPrank(alice);
        hook.claimTokens(currency1, alice, 1e18);
        assertEq(hook.tokensOwed(currency1, alice), earnings - 1e18);

        vm.expectRevert(TWAPOrderHook.InsufficientTokensOwed.selector);
        hook.claimTokens(currency1, alice, earnings);
        vm.stopPrank();
    }

    // --- Cancelling ---

    function test_cancelOrder_refundsUnsold() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 10, 10e18);
        uint256 balanceBefore = currency0.balanceOf(alice);

        _warpEpochs(4);
        vm.prank(alice);
        (uint256 refund, uint256 earnings) = hook.cancelOrder(key, orderKey, alice);

        assertEq(refund, 6e18);
        assertEq(currency0.balanceOf(alice) - balanceBefore, 6e18);
        assertApproxEqRel(earnings, 4e18, 0.01e18);
        assertEq(hook.tokensOwed(currency1, alice), earnings);

        assertEq(hook.getOrder(key, orderKey).sellRate, 0);
        (uint256 sellRateCurrent,) = hook.getOrderPool(key, true);
        assertEq(sellRateCurrent, 0);
        assertEq(hook.getSellRateEndingAtEpoch(key, true, orderKey.expiry), 0);
    }

    function test_cancelOrder_inSubmissionEpoch() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, false, 5, 5e18);
        uint256 balanceBefore = currency1.balanceOf(alice);

        vm.prank(alice);
        (uint256 refund, uint256 earnings) = hook.cancelOrder(key, orderKey, alice);

        assertEq(refund, 5e18);
        assertEq(earnings, 0);
        assertEq(currency1.balanceOf(alice) - balanceBefore, 5e18);
    }

    function test_cancelOrder_otherOrdersKeepSelling() public {
        TWAPOrderHook.OrderKey memory aliceKey = _submit(alice, true, 10, 10e18);
        TWAPOrderHook.OrderKey memory bobKey = _submit(bob, true, 10, 10e18);

        _warpEpochs(2);
        vm.prank(alice);
        hook.cancelOrder(key, aliceKey, alice);

        _warpEpochs(8);
        uint256 bobEarnings = hook.claimEarnings(key, bobKey);

        assertApproxEqRel(bobEarnings, 10e18, 0.02e18);
        assertEq(currency0.balanceOf(address(hook)), 0);
    }

    function test_cancelOrder_revertsUnauthorized() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 10, 10e18);

        vm.expectRevert(TWAPOrderHook.Unauthorized.selector);
        vm.prank(bob);
        hook.cancelOrder(key, orderKey, bob);
    }

    function test_cancelOrder_revertsAfterExpiry() public {
        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, 3, 3e18);

        _warpEpochs(4);
        vm.expectRevert(TWAPOrderHook.OrderExpired.selector);
        vm.prank(alice);
        hook.cancelOrder(key, orderKey, alice);
    }

    function test_cancelOrder_revertsOrderNotFound() public {
        TWAPOrderHook.OrderKey memory orderKey =
            TWAPOrderHook.OrderKey({owner: alice, expiry: hook.currentEpoch() + 5, zeroForOne: true});

        vm.expectRevert(TWAPOrderHook.OrderNotFound.selector);
        vm.prank(alice);
        hook.cancelOrder(key, orderKey, alice);
    }

    function test_setOperator() public {
        vm.expectEmit(address(hook));
        emit OperatorSet(alice, bob, true);
        vm.prank(alice);
        hook.setOperator(bob, true);
        assertTrue(hook.isOperator(alice, bob));

        vm.prank(alice);
        hook.setOperator(bob, false);
        assertFalse(hook.isOperator(alice, bob));
    }

    // --- Protocol fee ---

    function test_setProtocolFee() public {
        hook.setProtocolFee(500);
        assertEq(hook.protocolFee(), 500);
    }

    function test_setProtocolFee_revertsTooHigh() public {
        uint256 maxFee = hook.MAX_PROTOCOL_FEE();
        vm.expectRevert(TWAPOrderHook.ProtocolFeeTooHigh.selector);
        hook.setProtocolFee(maxFee + 1);
    }

    function test_setProtocolFee_revertsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        hook.setProtocolFee(100);
    }

    function test_protocolFee_accruedOnExecution() public {
        hook.setProtocolFee(500);
        _submit(alice, true, 10, 10e18);

        _warpEpochs(10);
        hook.executeOrders(key);

        uint256 earnings = currency1.balanceOf(address(hook));
        assertEq(hook.protocolFeesAccrued(currency1), earnings * 500 / 10_000);
        assertEq(hook.protocolFeesAccrued(currency0), 0);
    }

    function test_collectProtocolFees() public {
        hook.setProtocolFee(1_000);
        _submit(alice, true, 4, 4e18);
        _warpEpochs(4);
        hook.executeOrders(key);

        uint256 accrued = hook.protocolFeesAccrued(currency1);
        assertGt(accrued, 0);

        address treasury = makeAddr("treasury");
        assertEq(hook.collectProtocolFees(currency1, treasury), accrued);
        assertEq(currency1.balanceOf(treasury), accrued);
        assertEq(hook.protocolFeesAccrued(currency1), 0);
    }

    function test_collectProtocolFees_revertsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        hook.collectProtocolFees(currency1, alice);
    }

    // --- Native currency ---

    function test_nativeOrders() public {
        PoolKey memory nativeKey = _initNativePool();

        vm.deal(alice, 10 ether);
        uint32 expiry = hook.currentEpoch() + 5;

        vm.prank(alice);
        hook.submitOrder{value: 5 ether}(nativeKey, true, expiry, 5 ether);
        assertEq(address(hook).balance, 5 ether);

        TWAPOrderHook.OrderKey memory bobKey = _submitTo(nativeKey, bob, false, 5, 2e18);

        _warpEpochs(5);
        hook.executeOrders(nativeKey);
        assertEq(hook.claimEarnings(nativeKey, bobKey), 2e18);

        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        hook.claimTokens(CurrencyLibrary.ADDRESS_ZERO, bob, 0);
        assertEq(bob.balance - balanceBefore, 2e18);

        TWAPOrderHook.OrderKey memory aliceKey =
            TWAPOrderHook.OrderKey({owner: alice, expiry: expiry, zeroForOne: true});
        assertApproxEqRel(hook.claimEarnings(nativeKey, aliceKey), 5e18, 0.01e18);
    }

    function test_nativeOrders_revertsInvalidValue() public {
        PoolKey memory nativeKey = _initNativePool();
        vm.deal(alice, 10 ether);
        uint32 expiry = hook.currentEpoch() + 5;

        vm.expectRevert(TWAPOrderHook.InvalidNativeAmount.selector);
        vm.prank(alice);
        hook.submitOrder{value: 4 ether}(nativeKey, true, expiry, 5 ether);
    }

    // --- Fuzzing ---

    function testFuzz_cancelOrder_refundsRemainingEpochs(uint256 sellRate, uint8 numEpochs, uint8 elapsed) public {
        sellRate = bound(sellRate, 1e6, 1e18);
        numEpochs = uint8(bound(numEpochs, 2, 50));
        elapsed = uint8(bound(elapsed, 0, numEpochs - 1));

        TWAPOrderHook.OrderKey memory orderKey = _submit(alice, true, numEpochs, sellRate * numEpochs);

        _warpEpochs(elapsed);
        vm.prank(alice);
        (uint256 refund,) = hook.cancelOrder(key, orderKey, alice);

        assertEq(refund, sellRate * (numEpochs - elapsed));
        assertEq(currency0.balanceOf(address(hook)), 0);
    }

    function testFuzz_submitOrder_sellRate(uint256 amountIn, uint8 numEpochs) public {
        numEpochs = uint8(bound(numEpochs, 1, 100));
        amountIn = bound(amountIn, numEpochs, 100e18);

        uint32 expiry = hook.currentEpoch() + numEpochs;

        vm.prank(alice);
        (, uint256 sellRate) = hook.submitOrder(key, true, expiry, amountIn);

        assertEq(sellRate, amountIn / numEpochs);
    }

    // --- Helpers ---

    function _submit(address owner, bool zeroForOne, uint32 numEpochs, uint256 amountIn)
        internal
        returns (TWAPOrderHook.OrderKey memory)
    {
        return _submitTo(key, owner, zeroForOne, numEpochs, amountIn);
    }

    function _submitTo(PoolKey memory poolKey, address owner, bool zeroForOne, uint32 numEpochs, uint256 amountIn)
        internal
        returns (TWAPOrderHook.OrderKey memory orderKey)
    {
        orderKey =
            TWAPOrderHook.OrderKey({owner: owner, expiry: hook.currentEpoch() + numEpochs, zeroForOne: zeroForOne});

        vm.prank(owner);
        hook.submitOrder(poolKey, zeroForOne, orderKey.expiry, amountIn);
    }

    function _warpEpochs(uint256 numEpochs) internal {
        vm.warp(block.timestamp + numEpochs * EPOCH_LENGTH);
    }

    function _addFullRangeLiquidity(PoolKey memory poolKey, uint256 liquidity, uint256 value) internal {
        modifyLiquidityRouter.modifyLiquidity{value: value}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _initNativePool() internal returns (PoolKey memory nativeKey) {
        (nativeKey,) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(nativeKey, 10_000e18, 10_001 ether);
    }

    function _fundAndApprove(address account) internal {
        MockERC20(Currency.unwrap(currency0)).mint(account, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(account, 1_000e18);

        vm.startPrank(account);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }
}
