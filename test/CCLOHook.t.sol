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

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract CCLOHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    CCLOHook hook;
    PoolId poolId;

    address authorizedUser = address(0xFEED);
    uint256 originalHookChainId = 1;
    uint256 crossChainHookChainId = 2;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        bytes memory constructorArgs = abi.encode(manager, authorizedUser, originalHookChainId); //Add all the necessary constructor arguments from the hook
        deployCodeTo("CCLOHook.sol:CCLOHook", constructorArgs, flags);
        hook = CCLOHook(flags);
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = crossChainHookChainId;
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
}
