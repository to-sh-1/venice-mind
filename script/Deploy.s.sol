// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "../src/MockVVV.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Deploy Script
 * @dev Script to deploy the Venice Mind Burn system
 * @notice This script deploys the VVV token and factory contracts
 */
contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying contracts with account:", deployer);
        console.log("Account balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy VVV token
        MockVVV vvvToken = new MockVVV(deployer);
        console.log("VVV Token deployed at:", address(vvvToken));

        // Deploy VeniceMind implementation
        VeniceMind mindImpl = new VeniceMind();
        console.log(
            "VeniceMind implementation deployed at:",
            address(mindImpl)
        );

        // Deploy factory implementation
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        console.log(
            "VeniceMindFactory implementation deployed at:",
            address(factoryImpl)
        );

        // Deploy factory proxy
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector,
            address(vvvToken),
            deployer,
            address(mindImpl)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        VeniceMindFactory factory = VeniceMindFactory(address(proxy));
        console.log("VeniceMindFactory proxy deployed at:", address(factory));

        vm.stopBroadcast();

        // Verify deployment
        console.log("\n=== Deployment Summary ===");
        console.log("VVV Token:", address(vvvToken));
        console.log("VeniceMind implementation:", address(mindImpl));
        console.log("Factory Proxy:", address(factory));
        console.log("Factory Owner:", factory.owner());
        console.log("VVV Token Owner:", vvvToken.owner());
    }
}
