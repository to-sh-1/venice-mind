// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/**
 * @title Verify Script
 * @dev Script to verify deployed contracts on block explorers
 * @notice This script verifies the Venice Mind Burn contracts
 */
contract VerifyScript is Script {
    function run() external {
        // Get contract addresses from environment variables
        address vvvToken = vm.envAddress("VVV_TOKEN_ADDRESS");
        address factory = vm.envAddress("FACTORY_ADDRESS");

        console.log("Verifying VVV Token at:", vvvToken);
        console.log("Verifying Factory at:", factory);

        // Verify VVV Token
        string[] memory vvvInputs = new string[](3);
        vvvInputs[0] = "forge";
        vvvInputs[1] = "verify-contract";
        vvvInputs[2] = string(abi.encodePacked(vvvToken, ":MockVVV"));

        // Add constructor arguments for VVV Token
        // The constructor takes one argument: the owner address
        // You'll need to provide the actual owner address used during deployment
        address vvvOwner = vm.envAddress("VVV_OWNER_ADDRESS");
        vvvInputs = new string[](5);
        vvvInputs[0] = "forge";
        vvvInputs[1] = "verify-contract";
        vvvInputs[2] = string(abi.encodePacked(vvvToken, ":MockVVV"));
        vvvInputs[3] = "--constructor-args";
        vvvInputs[4] = string(abi.encodePacked("0x", vm.toString(vvvOwner)));

        // Verify Factory
        string[] memory factoryInputs = new string[](5);
        factoryInputs[0] = "forge";
        factoryInputs[1] = "verify-contract";
        factoryInputs[2] = string(
            abi.encodePacked(factory, ":VeniceMindFactory")
        );
        factoryInputs[3] = "--constructor-args";
        factoryInputs[4] = string(
            abi.encodePacked(
                "0x",
                vm.toString(vvvToken),
                "0x",
                vm.toString(vvvOwner)
            )
        );

        console.log("Run the following commands to verify contracts:");
        console.log("VVV Token verification:");
        console.log(
            string.concat(
                "forge verify-contract ",
                vm.toString(vvvToken),
                ' MockVVV --constructor-args $(cast abi-encode "constructor(address)" ',
                vm.toString(vvvOwner),
                ")"
            )
        );
        console.log("Factory verification:");
        console.log(
            string.concat(
                "forge verify-contract ",
                vm.toString(factory),
                ' VeniceMindFactory --constructor-args $(cast abi-encode "constructor(address,address)" ',
                vm.toString(vvvToken),
                " ",
                vm.toString(vvvOwner),
                ")"
            )
        );
    }
}
