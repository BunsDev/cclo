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
    event MessageSent( // The unique ID of the message.
        // The chain selector of the destination chain.
        // The address of the receiver on the destination chain.
        // The message being sent.
        // The token amount that was sent.
        // The fees paid for sending the message.
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        string message,
        Client.EVMTokenAmount tokenAmount,
        uint256 fees
    );

    // Event emitted when a message is received from another chain.
    event MessageReceived( // The unique ID of the message.
        // The chain selector of the source chain.
        // The address of the sender from the source chain.
        // The message that was received.
        // The token amount that was received.
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        string message,
        Client.EVMTokenAmount tokenAmount
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
    }

    // Struct representing a liquidity distribution strategy
    struct Strategy {
        uint256[] chainIds;
        uint256[] percentages;
    }

    // Struct to hold details of a message.
    struct Message {
        uint64 sourceChainSelector; // The chain selector of the source chain.
        address sender; // The address of the sender.
        string message; // The content of the message.
        address token; // received token.
        uint256 amount; // received amount.
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
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolKey memory key = data.key;
        PoolId poolId = key.toId();
        address sender = data.sender;
        IPoolManager.ModifyLiquidityParams memory params = data.params;

        Strategy storage strategy = strategies[poolId][data.strategyId];
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
            _settleDeltas(sender, key, delta);
        } else {
            // Calculate the liquidity to be added on each chain
            //            console.log("params.liquidityDelta", params.liquidityDelta);
            uint256[] memory liquidityAmounts = _calculateLiquidityAmounts(strategy, uint256(params.liquidityDelta));

            //Add liquidity to the user if the hook's chain ID exists in the strategy
            for (uint256 i = 0; i < strategy.chainIds.length; i++) {
                if (strategy.chainIds[i] != hookChainId) {
                    params.liquidityDelta -= int256(uint256(liquidityAmounts[i]));
                    // TODO: Add variables to manage cross-chain order logic
                    // Calculating token amounts to transfer etc...
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

    /// @notice Sends data to receiver on the destination chain.
    /// @dev Assumes your contract has sufficient native asset (e.g, ETH on Ethereum, MATIC on Polygon...).
    /// @param destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param receiver The address of the recipient on the destination blockchain.
    /// @param message The string message to be sent.
    /// @param token token address.
    /// @param amount token amount.
    /// @return messageId The ID of the message that was sent.
    function sendMessage(
        uint64 destinationChainSelector,
        address receiver,
        string calldata message,
        address token,
        uint256 amount
    ) external returns (bytes32 messageId) {
        // set the tokent amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({token: token, amount: amount});
        tokenAmounts[0] = tokenAmount;
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver), // ABI-encoded receiver address
            data: abi.encode(message), // ABI-encoded string message
            tokenAmounts: tokenAmounts, // Tokens amounts
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200_000}) // Additional arguments, setting gas limit and non-strict sequency mode
            ),
            feeToken: address(0) // Setting feeToken to zero address, indicating native asset will be used for fees
        });

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());

        // approve the Router to spend tokens on contract's behalf. I will spend the amount of the given token
        IERC20Minimal(token).approve(address(router), amount);

        // Get the fee required to send the message
        uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);

        // Reverts if this Contract doesn't have enough native tokens
        if (address(this).balance < fees) revert InsufficientFeeTokenAmount();

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: fees}(destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(messageId, destinationChainSelector, receiver, message, tokenAmount, fees);

        // Return the message ID
        return messageId;
    }

    /// handle a received message
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        bytes32 messageId = any2EvmMessage.messageId; // fetch the messageId
        uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector; // fetch the source chain identifier (aka selector)
        address sender = abi.decode(any2EvmMessage.sender, (address)); // abi-decoding of the sender address
        Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage.destTokenAmounts;
        address token = tokenAmounts[0].token; // we expect one token to be transfered at once but of course, you can transfer several tokens.
        uint256 amount = tokenAmounts[0].amount; // we expect one token to be transfered at once but of course, you can transfer several tokens.
        string memory message = abi.decode(any2EvmMessage.data, (string)); // abi-decoding of the sent string message
        receivedMessages.push(messageId);
        Message memory detail = Message(sourceChainSelector, sender, message, token, amount);
        messageDetail[messageId] = detail;

        emit MessageReceived(messageId, sourceChainSelector, sender, message, tokenAmounts[0]);
    }

    /// @notice Get the total number of received messages.
    /// @return number The total number of received messages.
    function getNumberOfReceivedMessages() external view returns (uint256 number) {
        return receivedMessages.length;
    }

    /// @notice Fetches details of a received message by message ID.
    /// @dev Reverts if the message ID does not exist.
    /// @param messageId The ID of the message whose details are to be fetched.
    /// @return sourceChainSelector The source chain identifier (aka selector).
    /// @return sender The address of the sender.
    /// @return message The received message.
    /// @return token The received token.
    /// @return amount The received token amount.
    function getReceivedMessageDetails(bytes32 messageId)
        external
        view
        returns (uint64 sourceChainSelector, address sender, string memory message, address token, uint256 amount)
    {
        Message memory detail = messageDetail[messageId];
        if (detail.sender == address(0)) revert MessageIdNotExist(messageId);
        return (detail.sourceChainSelector, detail.sender, detail.message, detail.token, detail.amount);
    }

    /// @notice Fetches details of a received message by its position in the received messages list.
    /// @dev Reverts if the index is out of bounds.
    /// @param index The position in the list of received messages.
    /// @return messageId The ID of the message.
    /// @return sourceChainSelector The source chain identifier (aka selector).
    /// @return sender The address of the sender.
    /// @return message The received message.
    /// @return token The received token.
    /// @return amount The received token amount.
    function getReceivedMessageAt(uint256 index)
        external
        view
        returns (
            bytes32 messageId,
            uint64 sourceChainSelector,
            address sender,
            string memory message,
            address token,
            uint256 amount
        )
    {
        if (index >= receivedMessages.length) {
            revert IndexOutOfBound(index, receivedMessages.length - 1);
        }
        messageId = receivedMessages[index];
        Message memory detail = messageDetail[messageId];
        return (messageId, detail.sourceChainSelector, detail.sender, detail.message, detail.token, detail.amount);
    }

    /// @notice Fetches the details of the last received message.
    /// @dev Reverts if no messages have been received yet.
    /// @return messageId The ID of the last received message.
    /// @return sourceChainSelector The source chain identifier (aka selector) of the last received message.
    /// @return sender The address of the sender of the last received message.
    /// @return message The last received message.
    /// @return token The last transferred token.
    /// @return amount The last transferred token amount.
    function getLastReceivedMessageDetails()
        external
        view
        returns (
            bytes32 messageId,
            uint64 sourceChainSelector,
            address sender,
            string memory message,
            address token,
            uint256 amount
        )
    {
        // Revert if no messages have been received
        if (receivedMessages.length == 0) revert NoMessageReceived();

        // Fetch the last received message ID
        messageId = receivedMessages[receivedMessages.length - 1];

        // Fetch the details of the last received message
        Message memory detail = messageDetail[messageId];

        return (messageId, detail.sourceChainSelector, detail.sender, detail.message, detail.token, detail.amount);
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
