// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {MockVVV} from "../src/MockVVV.sol";

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

        // Deploy factory
        VeniceMindFactory factory = new VeniceMindFactory(
            address(vvvToken),
            deployer
        );
        console.log("Factory deployed at:", address(factory));

        vm.stopBroadcast();

        // Verify deployment
        console.log("\n=== Deployment Summary ===");
        console.log("VVV Token:", address(vvvToken));
        console.log("Factory:", address(factory));
        console.log("Factory Owner:", factory.owner());
        console.log("VVV Token Owner:", vvvToken.owner());
    }
}
