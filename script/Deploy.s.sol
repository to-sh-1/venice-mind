// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Deploy Script
 * @dev Script to deploy the Venice Mind Burn system against an existing VVV token
 * @notice Uses a hardcoded VVV token address
 */
contract DeployScript is Script {
    address internal constant VVV_TOKEN_ADDRESS = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying contracts with account:", deployer);
        console.log("Account balance:", deployer.balance);
        console.log("Using existing VVV token:", VVV_TOKEN_ADDRESS);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy VeniceMind implementation
        VeniceMind mindImpl = new VeniceMind();
        console.log("VeniceMind implementation deployed at:", address(mindImpl));

        // Deploy factory implementation
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        console.log("VeniceMindFactory implementation deployed at:", address(factoryImpl));

        // Deploy factory proxy
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector, VVV_TOKEN_ADDRESS, deployer, address(mindImpl)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        VeniceMindFactory factory = VeniceMindFactory(address(proxy));
        console.log("VeniceMindFactory proxy deployed at:", address(factory));

        vm.stopBroadcast();

        // Verify deployment
        console.log("\n=== Deployment Summary ===");
        console.log("VVV Token:", VVV_TOKEN_ADDRESS);
        console.log("VeniceMind implementation:", address(mindImpl));
        console.log("Factory Proxy:", address(factory));
        console.log("Factory Owner:", factory.owner());
    }
}
