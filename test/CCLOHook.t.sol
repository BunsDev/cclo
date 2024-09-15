// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {CCLOHook} from "../src/CCLOHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// CCIP
import {
    CCIPLocalSimulator, IRouterClient, BurnMintERC677Helper
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";

contract CCLOHookTest is Test, Fixtures {
    ////////////////////////////////////////////////////////////////////////////////////////////////
    // CCIP Variables
    ////////////////////////////////////////////////////////////////////////////////////////////////
    CCIPLocalSimulator public ccipLocalSimulator;
    uint64 public destinationChainSelector;
    BurnMintERC677Helper public ccipBnMToken;
    CCLOHook hookReceiver;
    address hookReceiverAddress;
    ////////////////////////////////////////////////////////////////////////////////////////////////

    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    CCLOHook hook;
    address hookAddress;
    PoolId poolId;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    address authorizedUser = address(0xFEED);
    uint256 originalHookChainId = 1;
    uint256 crossChainHookChainId = 2;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        (token0, token1) = deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        ////////////////////////////////////////////////////////////////////////////////////////////////
        // CCIP Setup
        ////////////////////////////////////////////////////////////////////////////////////////////////
        ccipLocalSimulator = new CCIPLocalSimulator();
        (uint64 chainSelector, IRouterClient sourceRouter,,,, BurnMintERC677Helper ccipBnM,) =
            ccipLocalSimulator.configuration();
        destinationChainSelector = chainSelector;
        ccipBnMToken = ccipBnM;
        hookReceiverAddress = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x8888 << 144) // Namespace the hook to avoid collisions
        );
        ////////////////////////////////////////////////////////////////////////////////////////////////

        bytes memory constructorArgs = abi.encode(manager, authorizedUser, originalHookChainId, address(sourceRouter)); //Add all the necessary constructor arguments from the hook
        deployCodeTo("CCLOHook.sol:CCLOHook", constructorArgs, flags);
        // just for CCIP test
        deployCodeTo("CCLOHook.sol:CCLOHook", constructorArgs, hookReceiverAddress);
        hookReceiver = CCLOHook(hookReceiverAddress);
        // hookReceiverAddress = address(hookReceiver);
        console.log("Hook Receiver address:", hookReceiverAddress);
        ////////////////////////////////////////////////////////////////////////////////////////////////
        hook = CCLOHook(flags);
        hookAddress = address(hook);
        console.log("Hook address:", hookAddress);
        require(hookAddress == flags, "Hook address does not match flags");
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = originalHookChainId;
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 100;
        //        hook.addStrategy(0, chainIds, percentages);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        hook.addStrategy(poolId, 1, chainIds, percentages);
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function test_cannotAddLiquidity() public {
        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        bytes4 mintSelector =
            bytes4(keccak256("mint(PoolKey,int24,int24,uint256,uint256,uint256,address,uint256,bytes)"));

        bytes memory _calldata = abi.encodeWithSelector(
            mintSelector,
            key,
            tickLower,
            tickUpper,
            10_000e18,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        vm.expectRevert(bytes(""));
        (bool revertsAsExpected,) = address(posm).call(_calldata);
        assertTrue(revertsAsExpected, "expectRevert: call did not revert");
    }

    function test_AddLiquidityToStrategy1() public {
        // Provide full-range liquidity to the pool
        // Add some initial liquidity through the custom `addLiquidity` function
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(hookAddress, 1000 ether);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(hookAddress, 1000 ether);

        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint256 balance0Before = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1Before = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

        hook.addLiquidityWithCrossChainStrategy(
            key, IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, 1000e18, bytes32(0)), 1
        );

        uint256 balance0After = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1After = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

        assertEq(balance0Before - balance0After, 999999999999999999946);
        assertEq(balance1Before - balance1After, 999999999999999999946);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // CCIP Tests
    ////////////////////////////////////////////////////////////////////////////////////////////////
    function test_TokensLeaveSourceChain() external {
        deal(address(hookAddress), 1 ether);
        ccipBnMToken.drip(address(hookAddress));
        
        // Transfer tokens to the hook address
        token0.transfer(address(hookAddress), 1000e18);
        token1.transfer(address(hookAddress), 1000e18);
        
         // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );
        
        string memory messageToSend = "Hello, World!";
        uint256 amount0ToSend = 100;
        uint256 amount1ToSend = 500;

        uint256 token0BalanceOfSenderBefore = token0.balanceOf(address(hookAddress));
        uint256 token1BalanceOfSenderBefore = token1.balanceOf(address(hookAddress));
        
        console.log("Token0 balance before:", token0BalanceOfSenderBefore);
        console.log("Token1 balance before:", token1BalanceOfSenderBefore);

        // Send the cross-chain order
        bytes32 messageId = hook.sendMessage(
            destinationChainSelector,
            address(hookReceiver), 
            messageToSend,
            address(Currency.unwrap(token0)),
            amount0ToSend,
            address(Currency.unwrap(token1)),
            amount1ToSend
        );

        uint256 token0BalanceOfSenderAfter = token0.balanceOf(address(hookAddress));
        uint256 token1BalanceOfSenderAfter = token1.balanceOf(address(hookAddress));

        console.log("Token0 balance after:", token0BalanceOfSenderAfter);
        console.log("Token1 balance after:", token1BalanceOfSenderAfter);

        console.log("Message ID:", uint256(messageId));

        // Assertions
        assertEq(token0BalanceOfSenderAfter, token0BalanceOfSenderBefore - amount0ToSend, "Token0 balance not decreased correctly");
        assertEq(token1BalanceOfSenderAfter, token1BalanceOfSenderBefore - amount1ToSend, "Token1 balance not decreased correctly");
        assertTrue(messageId != bytes32(0), "Message ID should not be zero");
    }
    
    function test_TokensLeaveSenderAndReceivedByReceiverCCIP() external {
                deal(address(hookAddress), 1 ether);
        ccipBnMToken.drip(address(hookAddress));
        
        // Transfer tokens to the hook address
        token0.transfer(address(hookAddress), 1000e18);
        token1.transfer(address(hookAddress), 1000e18);
        
         // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );
        
        string memory messageToSend = "Hello, World!";
        uint256 amount0ToSend = 100;
        uint256 amount1ToSend = 500;

        uint256 token0BalanceOfSenderBefore = token0.balanceOf(address(hookAddress));
        uint256 token1BalanceOfSenderBefore = token1.balanceOf(address(hookAddress));
        
        console.log("Token0 balance before:", token0BalanceOfSenderBefore);
        console.log("Token1 balance before:", token1BalanceOfSenderBefore);

        // Send the cross-chain order
        bytes32 messageId = hook.sendMessage(
            destinationChainSelector,
            address(hookReceiver), 
            messageToSend,
            address(Currency.unwrap(token0)),
            amount0ToSend,
            address(Currency.unwrap(token1)),
            amount1ToSend
        );

        uint256 token0BalanceOfSenderAfter = token0.balanceOf(address(hookAddress));
        uint256 token1BalanceOfSenderAfter = token1.balanceOf(address(hookAddress));

        console.log("Token0 balance after:", token0BalanceOfSenderAfter);
        console.log("Token1 balance after:", token1BalanceOfSenderAfter);

        console.log("Message ID:");
        console.logBytes32((messageId));

        // Assertions
        assertEq(token0BalanceOfSenderAfter, token0BalanceOfSenderBefore - amount0ToSend, "Token0 balance not decreased correctly");
        assertEq(token1BalanceOfSenderAfter, token1BalanceOfSenderBefore - amount1ToSend, "Token1 balance not decreased correctly");
        assertTrue(messageId != bytes32(0), "Message ID should not be zero");
        
        // Check if the message was actually sent through the CCIP router
        (uint64 sourceChainSelector, address sender, string memory message, address token0MsgAddr, uint256 amount0, address token1MsgAddr, uint256 amount1) = hookReceiver.getReceivedMessageDetails(messageId);
        assertEq(sourceChainSelector, destinationChainSelector, "Source chain selector does not match");
        assertEq(sender, address(hook), "Sender does not match");
        assertEq(message, messageToSend, "Message does not match");
        assertEq(address(Currency.unwrap(token0)), address(token0MsgAddr), "Token0 does not match");        
        assertEq(amount0, amount0ToSend, "Amount0 does not match");
        assertEq(address(Currency.unwrap(token1)), address(token1MsgAddr), "Token1 does not match");
        assertEq(amount1, amount1ToSend, "Amount1 does not match");
    }   
}
