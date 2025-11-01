// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "../src/MockVVV.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VeniceMindFactoryTest is Test {
    VeniceMindFactory public factory;
    MockVVV public vvvToken;
    address public owner;
    address public user1;
    address public user2;
    address public user3;

    event MindCreated(
        address indexed creator,
        uint256 indexed mindId,
        address indexed mindAddress,
        string metadata
    );
    event GlobalBurn(
        uint256 indexed mindId,
        uint256 amount,
        uint256 globalTotal
    );
    event AllowlistUpdated(address indexed account, bool allowed);
    event AllowlistToggled(bool enabled);

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mock VVV token
        vvvToken = new MockVVV(owner);

        // Deploy factory
        vm.prank(owner);
        factory = new VeniceMindFactory(address(vvvToken), owner);

        // Mint tokens to users for testing
        vm.startPrank(owner);
        vvvToken.mint(user1, 1000e18);
        vvvToken.mint(user2, 1000e18);
        vvvToken.mint(user3, 1000e18);
        vm.stopPrank();
    }

    function testInitialState() public {
        assertEq(factory.owner(), owner);
        assertEq(factory.vvvToken(), address(vvvToken));
        assertEq(factory.globalTotalBurned(), 0);
        assertEq(factory.mindCounter(), 0);
        assertEq(factory.getMindCount(), 0);
        assertEq(factory.allowlistEnabled(), false);
    }

    function testCreateMind() public {
        string memory metadata = "Test Mind";

        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind(metadata);

        assertEq(mindId, 1);
        assertTrue(mindAddress != address(0));
        assertEq(factory.mindCounter(), 1);
        assertEq(factory.getMindCount(), 1);

        // Check mind info
        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(
            mindId
        );
        assertEq(mindInfo.creator, user1);
        assertEq(mindInfo.mindId, 1);
        assertEq(mindInfo.mindAddress, mindAddress);
        assertEq(mindInfo.createdAt, block.timestamp);
        assertEq(mindInfo.totalBurned, 0);
        assertEq(mindInfo.metadata, metadata);

        // Check that the mind contract is properly initialized
        VeniceMind mindContract = VeniceMind(mindAddress);
        assertEq(mindContract.owner(), address(factory));
        assertEq(address(mindContract.vvvToken()), address(vvvToken));
    }

    function testCreateMultipleMinds() public {
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        assertEq(mindId1, 1);
        assertEq(mindId2, 2);
        assertEq(factory.mindCounter(), 2);
        assertEq(factory.getMindCount(), 2);

        uint256[] memory mindIds = factory.getMindIds();
        assertEq(mindIds.length, 2);
        assertEq(mindIds[0], 1);
        assertEq(mindIds[1], 2);
    }

    function testBurnFromMind() public {
        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        // Deposit VVV tokens to the mind
        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        vvvToken.approve(mindAddress, depositAmount);
        vvvToken.transfer(mindAddress, depositAmount);
        vm.stopPrank();

        assertEq(factory.getMindVVVBalance(mindId), depositAmount);

        // Factory owner burns from the mind
        vm.expectEmit(true, false, false, true);
        emit GlobalBurn(mindId, depositAmount, depositAmount);

        vm.prank(owner);
        factory.burnFromMind(mindId);

        assertEq(factory.getMindVVVBalance(mindId), 0);
        assertEq(factory.globalTotalBurned(), depositAmount);
        assertEq(factory.getMindTotalBurned(mindId), depositAmount);

        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(
            mindId
        );
        assertEq(mindInfo.totalBurned, depositAmount);
    }

    function testBurnFromAllMinds() public {
        // Create multiple minds
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        // Deposit VVV tokens to both minds
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 50e18;

        vm.startPrank(user1);
        vvvToken.approve(mindAddress1, deposit1);
        vvvToken.transfer(mindAddress1, deposit1);
        vm.stopPrank();

        vm.startPrank(user2);
        vvvToken.approve(mindAddress2, deposit2);
        vvvToken.transfer(mindAddress2, deposit2);
        vm.stopPrank();

        assertEq(factory.getTotalVVVBalance(), deposit1 + deposit2);

        // Factory owner burns from all minds
        vm.prank(owner);
        factory.burnFromAllMinds();

        assertEq(factory.getTotalVVVBalance(), 0);
        assertEq(factory.globalTotalBurned(), deposit1 + deposit2);
        assertEq(factory.getMindTotalBurned(mindId1), deposit1);
        assertEq(factory.getMindTotalBurned(mindId2), deposit2);
    }

    function testAllowlist() public {
        // Enable allowlist
        vm.expectEmit(true, false, false, false);
        emit AllowlistToggled(true);

        vm.prank(owner);
        factory.toggleAllowlist(true);

        assertTrue(factory.allowlistEnabled());

        // User1 should not be able to create mind
        vm.expectRevert(VeniceMindFactory.NotAllowedToCreateMind.selector);
        vm.prank(user1);
        factory.createMind("Test Mind");

        // Add user1 to allowlist
        vm.expectEmit(true, false, false, false);
        emit AllowlistUpdated(user1, true);

        vm.prank(owner);
        factory.updateAllowlist(user1, true);

        assertTrue(factory.allowlist(user1));

        // Now user1 should be able to create mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        assertEq(mindId, 1);
        assertTrue(mindAddress != address(0));
    }

    function testOnlyOwnerCanBurnFromMind() public {
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        vvvToken.approve(mindAddress, depositAmount);
        vvvToken.transfer(mindAddress, depositAmount);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user1);
        factory.burnFromMind(mindId);
    }

    function testOnlyOwnerCanBurnFromAllMinds() public {
        vm.expectRevert();
        vm.prank(user1);
        factory.burnFromAllMinds();
    }

    function testOnlyOwnerCanUpdateAllowlist() public {
        vm.expectRevert();
        vm.prank(user1);
        factory.updateAllowlist(user2, true);

        vm.expectRevert();
        vm.prank(user1);
        factory.toggleAllowlist(true);
    }

    function testGetTotalBurnedBy() public {
        // Create minds
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        // Deposit and burn from mind1
        uint256 deposit1 = 100e18;
        vm.startPrank(user1);
        vvvToken.approve(mindAddress1, deposit1);
        vvvToken.transfer(mindAddress1, deposit1);
        vm.stopPrank();

        vm.prank(owner);
        factory.burnFromMind(mindId1);

        // Deposit and burn from mind2
        uint256 deposit2 = 50e18;
        vm.startPrank(user2);
        vvvToken.approve(mindAddress2, deposit2);
        vvvToken.transfer(mindAddress2, deposit2);
        vm.stopPrank();

        vm.prank(owner);
        factory.burnFromMind(mindId2);

        // Check total burned by factory (the factory is msg.sender when calling burn)
        assertEq(factory.getTotalBurnedBy(address(factory)), deposit1 + deposit2);
    }

    function testEmergencyWithdrawFromMind() public {
        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        // Deploy a mock ERC20 token
        MockVVV otherToken = new MockVVV(owner);

        // Mint other tokens to the mind contract
        vm.startPrank(owner);
        otherToken.mint(mindAddress, 50e18);
        vm.stopPrank();

        assertEq(otherToken.balanceOf(mindAddress), 50e18);

        // Factory owner emergency withdraws other tokens
        vm.prank(owner);
        factory.emergencyWithdrawFromMind(mindId, address(otherToken), user1);

        assertEq(otherToken.balanceOf(mindAddress), 0);
        assertEq(otherToken.balanceOf(user1), 50e18);
    }

    function testOnlyOwnerCanEmergencyWithdraw() public {
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        MockVVV otherToken = new MockVVV(owner);

        vm.startPrank(owner);
        otherToken.mint(mindAddress, 50e18);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user1);
        factory.emergencyWithdrawFromMind(mindId, address(otherToken), user1);
    }

    function testBurnFromNonExistentMind() public {
        vm.expectRevert("Mind does not exist");
        vm.prank(owner);
        factory.burnFromMind(999);
    }

    function testGetMindInfoNonExistent() public {
        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(999);
        assertEq(mindInfo.mindAddress, address(0));
    }

    function testFuzzCreateMind(string calldata metadata) public {
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind(metadata);

        assertEq(mindId, 1);
        assertTrue(mindAddress != address(0));

        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(
            mindId
        );
        assertEq(mindInfo.creator, user1);
        assertEq(mindInfo.metadata, metadata);
    }

    function testFuzzBurnFromMind(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000000e18);

        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        // Mint and deposit tokens
        vm.startPrank(owner);
        vvvToken.mint(user1, amount);
        vm.stopPrank();

        vm.startPrank(user1);
        vvvToken.approve(mindAddress, amount);
        vvvToken.transfer(mindAddress, amount);
        vm.stopPrank();

        // Burn from mind
        vm.prank(owner);
        factory.burnFromMind(mindId);

        assertEq(factory.globalTotalBurned(), amount);
        assertEq(factory.getMindTotalBurned(mindId), amount);
    }
}
