// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

contract CCLOHook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using StateLibrary for IPoolManager;

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////////////////////////////

    bytes internal constant ZERO_BYTES = bytes("");

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // State variables
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Authorized user address
    address public authorizedUser;

    // Mapping of hook's chain ID
    uint256 public hookChainId;

    // Mapping of strategy IDs to their respective liquidity distributions
    mapping(PoolId => mapping(uint256 => Strategy)) internal strategies;

    event Log(string message);
    event Log2(uint256 message);
    event Log3(int128 message);

    //    // Mapping of pool IDs to their respective cross-chain orders
    //    mapping(PoolId => CrossChainOrder) public ordersToBeFilled;

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Structs
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Event emitted when a cross-chain order is created
    event CrossChainOrderCreated(
        PoolId poolId, uint256 token0Amount, uint256 token1Amount, int24 lowerTick, int24 upperTick
    );

    //    // Event emitted when a cross-chain order is fulfilled
    //    event CrossChainOrderFulfilled(PoolId poolId);

    // Event emitted when a new strategy is added
    event StrategyAdded(PoolId poolId, uint256 strategyId, uint256[] chainIds, uint256[] liquidityPercentages);

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Structs
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Data passed during unlocking liquidity callback, includes sender and key info.
    /// @param sender Address of the sender initiating the unlock.
    /// @param key The pool key associated with the liquidity position.
    /// @param params Parameters for modifying liquidity.
    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        uint256 strategyId;
    }

    // Struct representing a liquidity distribution strategy
    struct Strategy {
        uint256[] chainIds;
        uint256[] percentages;
    }

    //    // Struct representing a cross-chain order
    //    struct CrossChainOrder {
    //        PoolId poolId;
    //        uint256 token0Amount;
    //        uint256 token1Amount;
    //        int24 lowerTick;
    //        int24 upperTick;
    //    }

    constructor(IPoolManager _poolManager, address _authorizedUser, uint256 _hookChainId) BaseHook(_poolManager) {
        hookChainId = _hookChainId;
        authorizedUser = _authorizedUser;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Modifier to restrict access to authorized users only
    modifier onlyAuthorized() {
        require(msg.sender == authorizedUser, "Only authorized users can add strategies");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Admin functions
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Function to set the authorized user
    function setAuthorizedUser(address newAuthorizedUser) public {
        authorizedUser = newAuthorizedUser;
    }

    // Function to set the authorized user
    function setHookChainId(uint256 newHookChainId) public {
        hookChainId = newHookChainId;
    }
    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Hook functions
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Hook that is called before liquidity is added. Forces user to use hook to add liquidity.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        require(sender == address(this), "Sender must be hook");
        return BaseHook.beforeAddLiquidity.selector;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Add Liquidity
    ////////////////////////////////////////////////////////////////////////////////////////////////

    //    // Function to add liquidity across multiple chains using a predefined strategy
    //    function addLiquidityCrossChain(
    //        PoolKey calldata key,
    //        uint256 strategyId,
    //        uint256 amount0Desired,
    //        uint256 amount1Desired,
    //        uint256 amount0Min,
    //        uint256 amount1Min,
    //        address to
    //    ) external returns (uint128 liquidity) {
    //        // Get the selected strategy
    //        Strategy storage strategy = strategies[strategyId];
    //
    //        // Calculate the liquidity to be added on each chain
    //        uint256[] memory liquidityAmounts = _calculateLiquidityAmounts(strategy, amount0Desired, amount1Desired);
    //
    //        // Add liquidity to the user if the hook's chain ID exists in the strategy
    //        for (uint256 i = 0; i < strategy.chainIds.length; i++) {
    //            if (strategy.chainIds[i] == hookChainId) {
    //                // Add liquidity to the user
    //                _addLiquidityToUser(key, liquidityAmounts[i], amount0Desired, amount1Desired, to);
    //            } else {
    //                params.liquidityDelta -= int256(uint256(liquidityToBridge));
    //                // Create a cross-chain order for the remaining liquidity
    //                _createCrossChainOrder(key, liquidityAmounts[i], amount0Desired, amount1Desired);
    //            }
    //        }
    //    }

    function addLiquidityWithCrossChainStrategy(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 strategyId
    ) external returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params, strategyId))), (BalanceDelta)
        );
    }

    /// @notice Callback function invoked during the unlock of liquidity, executing any required state changes.
    /// @param rawData Encoded data containing details for the unlock operation.
    /// @return Encoded result of the liquidity modification.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        emit Log("unlockCallback");
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolKey memory key = data.key;
        PoolId poolId = key.toId();
        address sender = data.sender;
        IPoolManager.ModifyLiquidityParams memory params = data.params;
        emit Log("unlockCallback 2");

        Strategy storage strategy = strategies[poolId][data.strategyId];
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
            _settleDeltas(sender, key, delta);
        } else {
            emit Log("unlockCallback 3");
            // Calculate the liquidity to be added on each chain
            //            console.log("params.liquidityDelta", params.liquidityDelta);
            emit Log2(uint256(params.liquidityDelta));
            uint256[] memory liquidityAmounts = _calculateLiquidityAmounts(strategy, uint256(params.liquidityDelta));
            emit Log2(uint256(liquidityAmounts[0]));

            emit Log("unlockCallback 4 ");
            //Add liquidity to the user if the hook's chain ID exists in the strategy
            for (uint256 i = 0; i < strategy.chainIds.length; i++) {
                emit Log2(uint256(strategy.chainIds[i]));
                emit Log2(uint256(hookChainId));
                if (strategy.chainIds[i] != hookChainId) {
                    emit Log("unlockCallback 5 ");
                    params.liquidityDelta -= int256(uint256(liquidityAmounts[i]));
                    emit Log2(uint256(params.liquidityDelta));
                    // TODO: Add variables to manage cross-chain order logic
                    // Calculating token amounts to transfer etc...
                }
            }

            if (params.liquidityDelta > 0) {
                emit Log("unlockCallback 6 ");
                (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
                emit Log3(int128(delta.amount0()));
                emit Log3(int128(delta.amount1()));
                _settleDeltas(sender, key, delta);
            }
            // TODO: Add cross-chain order logic with the variables from previous step
        }
        return abi.encode(delta);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Function to calculate the liquidity amounts for each chain based on the selected strategy
    function _calculateLiquidityAmounts(Strategy storage strategy, uint256 liquidityAmount)
        internal
        view
        returns (uint256[] memory liquidityAmounts)
    {
        liquidityAmounts = new uint256[](strategy.chainIds.length);

        for (uint256 i = 0; i < strategy.chainIds.length; i++) {
            uint256 percentage = strategy.percentages[i];
            liquidityAmounts[i] = (liquidityAmount * percentage) / 100;
        }
    }

    //    // Function to add liquidity to the user
    //    function _addLiquidityToUser(
    //        PoolKey calldata key,
    //        uint256 liquidityAmount,
    //        uint256 amount0Desired,
    //        uint256 amount1Desired,
    //        address to
    //    ) internal {
    //        // Add liquidity to the user
    //        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
    //            TickMath.getSqrtPriceAtTick(key.tickLower),
    //            TickMath.getSqrtPriceAtTick(key.tickUpper),
    //            amount0Desired,
    //            amount1Desired
    //        );
    //
    //        // Transfer the LP token to the user
    ////        UniswapV4ERC20(poolInfo[key.toId()].liquidityToken).mint(to, liquidity);
    //    }

    //    // Function to create a cross-chain order for the remaining liquidity
    //    function _createCrossChainOrder(
    //        PoolKey calldata key,
    //        uint256 liquidityAmount,
    //        uint256 amount0Desired,
    //        uint256 amount1Desired
    //    ) internal {
    //        // Create a cross-chain order
    //        CrossChainOrder storage order = ordersToBeFilled[key.toId()];
    //        order.poolId = key.toId();
    //        order.token0Amount = amount0Desired;
    //        order.token1Amount = amount1Desired;
    //        order.lowerTick = key.tickLower;
    //        order.upperTick = key.tickUpper;
    //    }

    //    // Function to fulfill a cross-chain order
    //    function fulfillCrossChainOrder(PoolId poolId) external {
    //        // Get the cross-chain order
    //        CrossChainOrder storage order = ordersToBeFilled[poolId];
    //
    //        // Fulfill the cross-chain order
    //        _fulfillCrossChainOrder(order);
    //
    //        // Emit an event to indicate the fulfillment of the cross-chain order
    //        emit CrossChainOrderFulfilled(poolId);
    //    }

    //    // Function to fulfill a cross-chain order
    //    function _fulfillCrossChainOrder(CrossChainOrder storage order) internal {
    //        // Add liquidity on the destination chain
    //        _addLiquidityOnDestinationChain(order.poolId, order.token0Amount, order.token1Amount);
    //
    //        // Transfer the LP token to the user
    //        UniswapV4ERC20(poolInfo[order.poolId].liquidityToken).mint(msg.sender, order.token0Amount);
    //    }

    //    // Function to add liquidity on the destination chain
    //    function _addLiquidityOnDestinationChain(
    //        PoolId poolId,
    //        uint256 amount0Desired,
    //        uint256 amount1Desired
    //    ) internal {
    //        // Add liquidity on the destination chain
    //        LiquidityAmounts.getLiquidityForAmounts(
    //            TickMath.getSqrtPriceAtTick(poolInfo[poolId].tickLower),
    //            TickMath.getSqrtPriceAtTick(poolInfo[poolId].tickUpper),
    //            amount0Desired,
    //            amount1Desired
    //        );
    //    }

    function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        poolManager.take(key.currency0, sender, uint256(uint128(-delta.amount0())));
        poolManager.take(key.currency1, sender, uint256(uint128(-delta.amount1())));
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        key.currency0.settle(poolManager, sender, uint256(int256(-delta.amount0())), false);
        key.currency1.settle(poolManager, sender, uint256(int256(-delta.amount1())), false);
        //        _settleDelta(sender, key.currency0, uint128(delta.amount0()));
        //        _settleDelta(sender, key.currency1, uint128(delta.amount1()));
    }

    //    /// @notice Calls settle or take depending on the signs of `delta0` and `delta1`
    //    function _settleOrTake(address sender, PoolKey memory sender, BalanceDelta delta) internal {
    //        int256 delta0 = int256(delta.amount0());
    //        int256 delta1 = int256(delta.amount1());
    //        if (delta0 < 0) key.currency0.settle(poolManager, sender, uint256(-delta0), useClaims);
    //        if (delta1 < 0) key.currency1.settle(poolManager, sender, uint256(-delta1), useClaims);
    //        if (delta0 > 0) key.currency0.take(poolManager, sender, uint256(delta0), useClaims);
    //        if (delta1 > 0) key.currency1.take(poolManager, sender, uint256(delta1), useClaims);
    //    }

    //    function _settleDelta(address sender, Currency currency, uint128 amount) internal {
    //
    //        if (currency.isNative()) {
    //            poolManager.settle{value: amount}(currency);
    //        } else {
    //            if (sender == address(this)) {
    //                currency.transfer(address(poolManager), amount);
    //            } else {
    //                IERC20(Currency.unwrap(currency)).transferFrom(sender, address(poolManager), amount);
    //            }
    //            poolManager.settle(currency);
    //        }
    //    }

    /// Function to add a new strategy
    function addStrategy(
        PoolId poolId,
        uint256 strategyId,
        uint256[] memory chainIds,
        uint256[] memory liquidityPercentages
    ) public {
        // Check that the strategy ID is not already in use for this pool
        require(strategies[poolId][strategyId].chainIds.length == 0, "Strategy ID already in use for this pool");

        // Check that the chain IDs and liquidity percentages arrays have the same length
        require(
            chainIds.length == liquidityPercentages.length,
            "Chain IDs and liquidity percentages arrays must have the same length"
        );

        // Check that the liquidity percentages add up to 100
        uint256 totalLiquidityPercentage = 0;
        for (uint256 i = 0; i < liquidityPercentages.length; i++) {
            totalLiquidityPercentage += liquidityPercentages[i];
        }
        require(totalLiquidityPercentage == 100, "Liquidity percentages must add up to 100");

        // Add the new strategy to the strategies mapping
        strategies[poolId][strategyId] = Strategy({chainIds: chainIds, percentages: liquidityPercentages});

        // Emit an event to notify that a new strategy has been added
        emit StrategyAdded(poolId, strategyId, chainIds, liquidityPercentages);
    }
}
