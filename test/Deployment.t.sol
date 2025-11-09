// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "../src/MockVVV.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Deployment Test
 * @dev Test to verify contracts can be deployed and basic functionality works
 */
contract DeploymentTest is Test {
    VeniceMindFactory public factory;
    MockVVV public vvvToken;
    address public owner;
    address public user1;

    function deployFactory(
        address token,
        address owner_
    ) internal returns (VeniceMindFactory) {
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector,
            token,
            owner_,
            address(mindImpl)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        return VeniceMindFactory(address(proxy));
    }

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
    }

    function testDeployment() public {
        // Deploy VVV token
        vm.prank(owner);
        vvvToken = new MockVVV(owner);

        assertEq(vvvToken.owner(), owner);
        assertEq(vvvToken.name(), "Venice Vision Vault");
        assertEq(vvvToken.symbol(), "VVV");

        // Deploy factory
        factory = deployFactory(address(vvvToken), owner);

        assertEq(factory.owner(), owner);
        assertEq(factory.vvvToken(), address(vvvToken));
        assertEq(factory.globalTotalBurned(), 0);
        assertEq(factory.getMindCount(), 0);

        console.log("VVV Token deployed at:", address(vvvToken));
        console.log("Factory deployed at:", address(factory));
    }

    function testCreateMindAfterDeployment() public {
        // Deploy contracts
        vm.prank(owner);
        vvvToken = new MockVVV(owner);
        factory = deployFactory(address(vvvToken), owner);

        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        assertEq(mindId, 1);
        assertTrue(mindAddress != address(0));
        assertEq(factory.getMindCount(), 1);

        // Verify mind contract
        VeniceMind mindContract = VeniceMind(mindAddress);
        assertEq(mindContract.owner(), address(factory));
        assertEq(address(mindContract.vvvToken()), address(vvvToken));

        console.log("Mind created with ID:", mindId);
        console.log("Mind deployed at:", mindAddress);
    }

    function testFullWorkflow() public {
        // Deploy contracts
        vm.prank(owner);
        vvvToken = new MockVVV(owner);
        factory = deployFactory(address(vvvToken), owner);

        // Mint tokens to user
        vm.prank(owner);
        vvvToken.mint(user1, 1000e18);

        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        // User deposits VVV tokens
        vm.startPrank(user1);
        vvvToken.approve(mindAddress, 100e18);
        vvvToken.transfer(mindAddress, 100e18);
        vm.stopPrank();

        // Verify deposit
        VeniceMind mindContract = VeniceMind(mindAddress);
        assertEq(mindContract.getVVVBalance(), 100e18);

        // Factory owner burns tokens
        vm.prank(owner);
        factory.burnFromMind(mindId);

        // Verify burn
        assertEq(mindContract.getVVVBalance(), 0);
        assertEq(factory.globalTotalBurned(), 100e18);
        assertEq(factory.getMindTotalBurned(mindId), 100e18);

        console.log("Full workflow completed successfully");
        console.log("Total burned globally:", factory.globalTotalBurned());
    }
}
