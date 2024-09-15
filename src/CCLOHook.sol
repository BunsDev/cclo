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
//import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {CCIPReceiver} from "chainlink-local/lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "chainlink-local/lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "chainlink-local/lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IRouter} from "chainlink-local/lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouter.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

contract CCLOHook is CCIPReceiver, BaseHook {
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
    // Variables
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Storage variables.
    bytes32[] public receivedMessages; // Array to keep track of the IDs of received messages.
    mapping(bytes32 => Message) public messageDetail; // Mapping from message ID to Message struct, storing details of each received message.

    // Authorized user address
    address public authorizedUser;

    // Mapping of hook's chain ID
    uint256 public hookChainId;

    // Mapping of strategy IDs to their respective liquidity distributions
    mapping(PoolId => mapping(uint256 => Strategy)) internal strategies;

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Event emitted when a new strategy is added
    event StrategyAdded(PoolId poolId, uint256 strategyId, uint256[] chainIds, uint256[] liquidityPercentages);

    // Event emitted when a message is sent to another chain.
    // The chain selector of the destination chain.
    // The address of the receiver on the destination chain.
    // The message being sent.
    // The token0 amount that was sent.
    // The token1 amount that was sent.
    // The fees paid for sending the message.
    event MessageSent( // The unique ID of the message.
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        Client.EVMTokenAmount tokenAmount0,
        Client.EVMTokenAmount tokenAmount1,
        uint256 fees
    );

    // Event emitted when a message is received from another chain.
    // The chain selector of the source chain.
    // The address of the sender from the source chain.
    // The message that was received.
    // The token amount that was received.
    event MessageReceived( // The unique ID of the message.
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        Client.EVMTokenAmount tokenAmount0,
        Client.EVMTokenAmount tokenAmount1
    );

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
        bool isCrossChainIncoming;
    }

    // Struct representing a liquidity distribution strategy
    struct Strategy {
        uint256[] chainIds;
        uint256[] percentages;
    }

    // Struct to hold details of a message.
    struct Message {
        uint64 sourceChainSelector;
        address sender;
        address token0;
        uint256 amount0;
        address token1;
        uint256 amount1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
    }

    struct CCIPReceiveParams {
        address recipient;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        address token0Address;
        uint256 token0Amount;
        address token1Address;
        uint256 token1Amount;
    }

    struct SendMessageParams {
        uint64 destinationChainSelector;
        address receiver;
        address token0;
        uint256 amount0;
        address token1;
        uint256 amount1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // Custom errors to provide more descriptive revert messages.
    error NoMessageReceived(); // Used when trying to access a message but no messages have been received.
    error IndexOutOfBound(uint256 providedIndex, uint256 maxIndex); // Used when the provided index is out of bounds.
    error MessageIdNotExist(bytes32 messageId); // Used when the provided message ID does not exist.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error InsufficientFeeTokenAmount(); // Used when the contract balance isn't enough to pay fees.

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Constructor initializes the contract with the router address.
    /// @param router The address of the router contract.
    constructor(IPoolManager _poolManager, address _authorizedUser, uint256 _hookChainId, address router)
        BaseHook(_poolManager)
        CCIPReceiver(router)
    {
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
    // Hook definitions
    ////////////////////////////////////////////////////////////////////////////////////////////////

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

    function addLiquidityWithCrossChainStrategy(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 strategyId
    ) external returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params, strategyId, false))), (BalanceDelta)
        );
    }

    /// @notice Callback function invoked during the unlock of liquidity, executing any required state changes.
    /// @param rawData Encoded data containing details for the unlock operation.
    /// @return Encoded result of the liquidity modification.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolKey memory key = data.key;
        PoolId poolId = key.toId();
        address sender = data.sender;
        bool isCrossChainIncoming = data.isCrossChainIncoming;
        IPoolManager.ModifyLiquidityParams memory params = data.params;

        Strategy storage strategy = strategies[poolId][data.strategyId];
        BalanceDelta delta;

        if (isCrossChainIncoming) {
            return abi.encode(delta);
        }

        if (data.params.liquidityDelta < 0) {
            (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
            _settleDeltas(sender, key, delta);
        } else {
            // Calculate the liquidity to be added on each chain
            //            console.log("params.liquidityDelta", params.liquidityDelta);
            uint256[] memory liquidityAmounts = _calculateLiquidityAmounts(strategy, uint256(params.liquidityDelta));

            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

            //Add liquidity to the user if the hook's chain ID exists in the strategy
            for (uint256 i = 0; i < strategy.chainIds.length; i++) {
                if (strategy.chainIds[i] != hookChainId) {
                    (uint256 amount0, uint256 amount1) =
                        _calculateTokenAmounts(params, liquidityAmounts[i], sqrtPriceX96);
                    params.liquidityDelta -= int256(uint256(liquidityAmounts[i]));
                    _transferCrossChain(strategy.chainIds[i], key, amount0, amount1, sender);
                }
            }

            if (params.liquidityDelta > 0) {
                (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
                _settleDeltas(sender, key, delta);
            }
            // TODO: Add cross-chain order logic with the variables from previous step
        }
        return abi.encode(delta);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // CCIP Sending and Receiving
    ////////////////////////////////////////////////////////////////////////////////////////////////

    function sendMessage(
        uint64 destinationChainSelector,
        address receiver,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        uint24 fee,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper
    ) external returns (bytes32 messageId) {
        SendMessageParams memory params = SendMessageParams({
            destinationChainSelector: destinationChainSelector,
            receiver: receiver,
            token0: token0,
            amount0: amount0,
            token1: token1,
            amount1: amount1,
            fee: fee, // You might want to set this appropriately
            tickSpacing: tickSpacing, // You might want to set this appropriately
            tickLower: tickLower, // You might want to set this appropriately
            tickUpper: tickUpper // You might want to set this appropriately
        });
        return _sendMessage(params);
    }

    function _sendMessage(SendMessageParams memory params) internal returns (bytes32 messageId) {
        // Encode the message data
        bytes memory encodedMessage =
            abi.encode(params.receiver, params.fee, params.tickSpacing, params.tickLower, params.tickUpper);

        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](2);
        tokenAmounts[0] = Client.EVMTokenAmount({token: params.token0, amount: params.amount0});
        tokenAmounts[1] = Client.EVMTokenAmount({token: params.token1, amount: params.amount1});

        // Create an EVM2AnyMessage struct in memory
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(params.receiver),
            data: encodedMessage,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0)
        });

        // Initialize a router client instance
        IRouterClient router = IRouterClient(this.getRouter());

        // Approve the Router to spend tokens on contract's behalf
        IERC20Minimal(params.token0).approve(address(router), params.amount0);
        IERC20Minimal(params.token1).approve(address(router), params.amount1);

        // Get the fee required to send the message
        uint256 fees = router.getFee(params.destinationChainSelector, evm2AnyMessage);

        // Reverts if this Contract doesn't have enough native tokens
        if (address(this).balance < fees) revert InsufficientFeeTokenAmount();

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: fees}(params.destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(
            messageId, params.destinationChainSelector, params.receiver, tokenAmounts[0], tokenAmounts[1], fees
        );

        // Return the message ID
        return messageId;
    }

    /// handle a received message
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        bytes32 messageId = any2EvmMessage.messageId;
        uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector;
        address sender = abi.decode(any2EvmMessage.sender, (address));
        receivedMessages.push(messageId);

        CCIPReceiveParams memory params;
        (params.recipient, params.fee, params.tickSpacing, params.tickLower, params.tickUpper) =
            abi.decode(any2EvmMessage.data, (address, uint24, int24, int24, int24));

        Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage.destTokenAmounts;

        params.token0Address = tokenAmounts[0].token;
        params.token0Amount = tokenAmounts[0].amount;
        params.token1Address = tokenAmounts[1].token;
        params.token1Amount = tokenAmounts[1].amount;

        IERC20Minimal(params.token0Address).approve(address(poolManager), type(uint256).max);
        IERC20Minimal(params.token1Address).approve(address(poolManager), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(params.token0Address),
            currency1: Currency.wrap(params.token1Address),
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(address(this))
        });
        PoolId poolId = key.toId();

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        _processLiquidity(key, params, currentSqrtPriceX96);

        // Refund remaining tokens to recipient
        _refundRemainingTokens(params);

        // Emit an event with message details
        emit MessageReceived(messageId, sourceChainSelector, sender, tokenAmounts[0], tokenAmounts[1]);

        messageDetail[messageId] = Message({
            sourceChainSelector: sourceChainSelector,
            sender: sender,
            token0: params.token0Address,
            amount0: params.token0Amount,
            token1: params.token1Address,
            amount1: params.token1Amount,
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper
        });
    }

    /// @notice Get the total number of received messages.
    /// @return number The total number of received messages.
    function getNumberOfReceivedMessages() external view returns (uint256 number) {
        return receivedMessages.length;
    }

    function getReceivedMessageDetails(bytes32 messageId)
        external
        view
        returns (
            uint64 sourceChainSelector,
            address sender,
            address token0,
            uint256 amount0,
            address token1,
            uint256 amount1,
            uint24 fee,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper
        )
    {
        Message memory detail = messageDetail[messageId];
        if (detail.sender == address(0)) revert MessageIdNotExist(messageId);
        return (
            detail.sourceChainSelector,
            detail.sender,
            detail.token0,
            detail.amount0,
            detail.token1,
            detail.amount1,
            detail.fee,
            detail.tickSpacing,
            detail.tickLower,
            detail.tickUpper
        );
    }

    function getReceivedMessageAt(uint256 index)
        external
        view
        returns (
            bytes32 messageId,
            uint64 sourceChainSelector,
            address sender,
            address token0,
            uint256 amount0,
            address token1,
            uint256 amount1
        )
    {
        if (index >= receivedMessages.length) {
            revert IndexOutOfBound(index, receivedMessages.length - 1);
        }
        messageId = receivedMessages[index];
        Message memory detail = messageDetail[messageId];
        return (
            messageId,
            detail.sourceChainSelector,
            detail.sender,
            detail.token0,
            detail.amount0,
            detail.token1,
            detail.amount1
        );
    }

    function getLastReceivedMessageDetails()
        external
        view
        returns (
            bytes32 messageId,
            uint64 sourceChainSelector,
            address sender,
            address token0,
            uint256 amount0,
            address token1,
            uint256 amount1
        )
    {
        // Revert if no messages have been received
        if (receivedMessages.length == 0) revert NoMessageReceived();

        // Fetch the last received message ID
        messageId = receivedMessages[receivedMessages.length - 1];

        // Fetch the details of the last received message
        Message memory detail = messageDetail[messageId];

        return (
            messageId,
            detail.sourceChainSelector,
            detail.sender,
            detail.token0,
            detail.amount0,
            detail.token1,
            detail.amount1
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////////////////////////////

    function _processLiquidity(PoolKey memory key, CCIPReceiveParams memory params, uint160 currentSqrtPriceX96)
        private
    {
        uint160 lowerSqrtPriceX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 upperSqrtPriceX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96, lowerSqrtPriceX96, upperSqrtPriceX96, params.token0Amount, params.token1Amount
        );

        IPoolManager.ModifyLiquidityParams memory modifyParams = IPoolManager.ModifyLiquidityParams({
            liquidityDelta: int256(uint256(liquidity)),
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            salt: bytes32(0)
        });

        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(msg.sender, key, modifyParams, 1, true))), (BalanceDelta)
        );

        params.token0Amount -= uint256(uint128(delta.amount0()));
        params.token1Amount -= uint256(uint128(delta.amount1()));
    }

    function _refundRemainingTokens(CCIPReceiveParams memory params) private {
        if (params.token0Amount > 0) {
            IERC20Minimal(params.token0Address).transfer(params.recipient, params.token0Amount);
        }

        if (params.token1Amount > 0) {
            IERC20Minimal(params.token1Address).transfer(params.recipient, params.token1Amount);
        }
    }

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

    function _calculateTokenAmounts(
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 liquidity,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            // Current price is below the range, only token0 is needed
            amount0 = FullMath.mulDiv(liquidity << 96, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96) / sqrtPriceAX96;
            amount1 = 0;
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            // Current price is within the range, both tokens are needed
            amount0 = FullMath.mulDiv(liquidity << 96, sqrtPriceBX96 - sqrtPriceX96, sqrtPriceBX96) / sqrtPriceX96;
            amount1 = FullMath.mulDiv(liquidity, sqrtPriceX96 - sqrtPriceAX96, FixedPoint96.Q96);
        } else {
            // Current price is above the range, only token1 is needed
            amount0 = 0;
            amount1 = FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
        }
    }

    function _transferCrossChain(
        uint256 destinationChainId,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal {
        // Get the current tick from the pool
        (, int24 tick,,) = poolManager.getSlot0(key.toId());

        // TODO: Fix these
        // Calculate the tick range (this is an example, adjust as needed)
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = tick - tickSpacing;
        int24 tickUpper = tick + tickSpacing;

        SendMessageParams memory params = SendMessageParams({
            destinationChainSelector: uint64(destinationChainId),
            receiver: recipient,
            token0: Currency.unwrap(key.currency0),
            amount0: amount0,
            token1: Currency.unwrap(key.currency1),
            amount1: amount1,
            fee: key.fee,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        _sendMessage(params);
    }

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
