
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

/// @notice Forge script for deploying v4 & hooks to **anvil**
/// @dev This script only works on an anvil RPC because v4 exceeds bytecode limits
contract CCLOHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    address constant ETH_SEPOLIA_POOL_MANAGER = 0xCa6DBBe730e31fDaACaA096821199EEED5AD84aE;
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x95f211699D44E4B4afcB47B16417724De12D099b;

    uint256 BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 ETH_SEPOLIA_CHAIN_ID = 11155111;

    //////////////////////////////////////////////////////////////
    // CCIP related values
    //////////////////////////////////////////////////////////////
    uint256 constant ETH_SEPOLIA_CCIP_CHAIN_ID = 0;
    uint256 constant BASE_SEPOLIA_CCIP_CHAIN_ID = 6;
    uint256 constant OP_SEPOLIA_CCIP_CHAIN_ID = 5;

    address constant ETH_SEPOLIA_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant BASE_SEPOLIA_CCIP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address constant OP_SEPOLIA_CCIP_ROUTER = 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57;
    //////////////////////////////////////////////////////////////

    function setUp() public {}

    function run() public {
        vm.broadcast();
        IPoolManager manager = IPoolManager(ETH_SEPOLIA_POOL_MANAGER); // taken from Haardik's deployment
        address authorizedUser = address(0xFEED);

        // hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, permissions, type(CCLOHook).creationCode, abi.encode(address(manager), authorizedUser, ETH_SEPOLIA_CHAIN_ID, address(ETH_SEPOLIA_ROUTER)));

        // ----------------------------- //
        // Deploy the hook using CREATE2 //
        // ----------------------------- //
        vm.broadcast();
        CCLOHook hook = new CCLOHook{salt: salt}(manager, authorizedUser, ETH_SEPOLIA_CHAIN_ID, ETH_SEPOLIA_ROUTER);
        require(address(hook) == hookAddress, "CCLOHookScript: ETH Sepolia hook address mismatch");

    }
}
