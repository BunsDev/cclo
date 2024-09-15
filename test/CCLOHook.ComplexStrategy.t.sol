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
    BurnMintERC677Helper public ccipBnMToken;

    address public sourceRouterAddress;
    address public destinationRouterAddress;

    uint64 public destinationChainSelector;
    ////////////////////////////////////////////////////////////////////////////////////////////////

    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    CCLOHook hookSource;
    CCLOHook hookDestination;
    address hookAddressSource;
    address hookAddressDestination;

    PoolId poolId;
    PoolId poolId2;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    address authorizedUser = address(0xFEED);
    uint256 sourceHookChainId = 1;
    uint256 destinationHookChainId = 2;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    PoolKey key2;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        (token0, token1) = deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flagsSourceChain = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        address flagsDestinationChain = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x8888 << 144) // Namespace the hook to avoid collisions
        );

        ////////////////////////////////////////////////////////////////////////////////////////////////
        // CCIP Setup
        ////////////////////////////////////////////////////////////////////////////////////////////////
        ccipLocalSimulator = new CCIPLocalSimulator();
        (
            uint64 chainSelector,
            IRouterClient sourceRouter,
            IRouterClient destinationRouter,
            ,
            ,
            BurnMintERC677Helper ccipBnM,
        ) = ccipLocalSimulator.configuration();
        destinationChainSelector = chainSelector;
        ccipBnMToken = ccipBnM;

        sourceRouterAddress = address(sourceRouter);
        destinationRouterAddress = address(destinationRouter);

        ////////////////////////////////////////////////////////////////////////////////////////////////

        bytes memory constructorArgs = abi.encode(manager, authorizedUser, sourceHookChainId, sourceRouterAddress); //Add all the necessary constructor arguments from the hook
        deployCodeTo("CCLOHook.sol:CCLOHook", constructorArgs, flagsSourceChain);

        hookSource = CCLOHook(flagsSourceChain);
        ////////////////////////////////////////////////////////////////////////////////////////////////
        hookAddressSource = address(hookSource);
        require(hookAddressSource == flagsSourceChain, "Hook address does not match flags");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hookSource));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        deployFreshManagerAndRouters();
        bytes memory constructorArgs2 =
            abi.encode(manager, authorizedUser, destinationHookChainId, destinationRouterAddress); //Add all the necessary constructor arguments from the hook
        deployCodeTo("CCLOHook.sol:CCLOHook", constructorArgs2, flagsDestinationChain);
        hookDestination = CCLOHook(flagsDestinationChain);
        hookAddressDestination = address(hookDestination);
        require(hookAddressDestination == flagsDestinationChain, "Hook address does not match flags");

        // Create the pool
        key2 = PoolKey(currency0, currency1, 3000, 60, IHooks(hookDestination));
        poolId2 = key2.toId();
        manager.initialize(key2, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = sourceHookChainId;
        chainIds[1] = destinationHookChainId;
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 40;
        percentages[1] = 60;
        uint64[] memory selectors = new uint64[](2);
        selectors[0] = chainSelector;
        selectors[1] = chainSelector;

        address[] memory hooks = new address[](2);
        hooks[0] = hookAddressSource;
        hooks[1] = hookAddressDestination;
        hookSource.addStrategy(poolId, 1, chainIds, percentages, selectors, hooks);
    }

    function test_AddLiquidityToCrossChainStrategy() public {
        deal(address(hookAddressSource), 1 ether);
        deal(address(hookDestination), 1 ether);
        ccipBnMToken.drip(address(hookSource));
        ccipBnMToken.drip(address(hookDestination));
        // Provide full-range liquidity to the pool
        // Add some initial liquidity through the custom `addLiquidity` function
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(hookAddressSource, 1000 ether);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(hookAddressSource, 1000 ether);

        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint256 balance0Before = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1Before = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

        hookSource.addLiquidityWithCrossChainStrategy(
            key, IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, 10_000_000, bytes32(0)), 1
        );

        uint256 balance0AfterManager = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(manager));
        uint256 balance1AfterManager = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(manager));

        uint256 balance0After = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1After = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

        assertEq(balance0Before - balance0After, 9_999_999);
        assertEq(balance1Before - balance1After, 9_999_999);
    }
}
