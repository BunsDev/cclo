// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {CCLOHook} from "../src/CCLOHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/// @notice Forge script for deploying v4 & hooks to **anvil**
/// @dev This script only works on an anvil RPC because v4 exceeds bytecode limits
contract CCLOHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    address constant ETH_SEPOLIA_POOL_MANAGER = 0xCa6DBBe730e31fDaACaA096821199EEED5AD84aE;
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x95f211699D44E4B4afcB47B16417724De12D099b;

    uint256 BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 ETH_SEPOLIA_CHAIN_ID = 11155111;

    uint64 constant BASE_SEPOLIA_CHAIN_SELECTOR = 10344971235874465080;
    uint64 constant ETH_SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;

    //////////////////////////////////////////////////////////////
    // CCIP related values
    //////////////////////////////////////////////////////////////
    uint256 constant ETH_SEPOLIA_CCIP_CHAIN_ID = 0;
    uint256 constant BASE_SEPOLIA_CCIP_CHAIN_ID = 6;
    uint256 constant OP_SEPOLIA_CCIP_CHAIN_ID = 5;

    address constant ETH_SEPOLIA_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant BASE_SEPOLIA_CCIP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address constant OP_SEPOLIA_CCIP_ROUTER = 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57;

    address constant CCLO_HOOK_ADDRESS_BASE_SEPOLIA = 0x696907c68D922c289582dA6c35E4c49E3df44800;
    address constant CCLO_HOOK_ADDRESS_ETH_SEPOLIA = 0x92A1Fd49D8A7e6ecf3414754257bBF7652750800;

    // token addresses base
    // CCIP - BNM = 0x88A2d74F47a237a62e7A51cdDa67270CE381555e
    // USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    // eth
    // CCIP - BNM = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05
    // USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

    // USDC
    address constant BASE_SEPOLIA_TOKEN0 = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    // BnM
    address constant BASE_SEPOLIA_TOKEN1 = 0x88A2d74F47a237a62e7A51cdDa67270CE381555e;

    // USDC
    address constant ETH_SEPOLIA_TOKEN0 = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    // BnM
    address constant ETH_SEPOLIA_TOKEN1 = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;
    //////////////////////////////////////////////////////////////

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes constant ZERO_BYTES = new bytes(0);

    bytes32 constant BASE_SEPOLIA_POOL_ID = 0xbf49515d46810841973e073336d7c8730a62cd91736e1102110e0dea1bf386e4;
    bytes32 constant ETH_SEPOLIA_POOL_ID = 0x848f63ece887a05062748a0304a89547a85d329c448da27760bab6243fa54087;

    function setUp() public {}

    function run() public {
        address token0 = ETH_SEPOLIA_TOKEN0;
        address token1 = ETH_SEPOLIA_TOKEN1;

        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        CCLOHook hook = CCLOHook(CCLO_HOOK_ADDRESS_ETH_SEPOLIA);

        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(CCLO_HOOK_ADDRESS_ETH_SEPOLIA));
        PoolId id = PoolIdLibrary.toId(key);
        bytes32 idBytes = PoolId.unwrap(id);
        //        PoolId id2 = PoolIdLibrary.wrap(BASE_SEPOLIA_POOL_ID);

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = BASE_SEPOLIA_CHAIN_ID;
        chainIds[1] = ETH_SEPOLIA_CHAIN_ID;
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 40;
        percentages[1] = 60;
        uint64[] memory selectors = new uint64[](2);
        selectors[0] = BASE_SEPOLIA_CHAIN_SELECTOR;
        selectors[1] = ETH_SEPOLIA_CHAIN_SELECTOR;

        address[] memory hooks = new address[](2);
        hooks[0] = CCLO_HOOK_ADDRESS_BASE_SEPOLIA;
        hooks[1] = CCLO_HOOK_ADDRESS_ETH_SEPOLIA;

        console.log("Hook address: ", CCLO_HOOK_ADDRESS_ETH_SEPOLIA);
        console.log("Hook address: ", address(hook));

        vm.startBroadcast();
        hook.addStrategy(id, 1, chainIds, percentages, selectors, hooks);
        vm.stopBroadcast();
    }
}
