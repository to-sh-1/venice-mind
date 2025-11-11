// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "../src/MockVVV.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

    function _depositToMind(
        address contributor,
        address mindAddress,
        uint256 amount
    ) internal {
        vm.startPrank(contributor);
        vvvToken.approve(mindAddress, amount);
        VeniceMind(mindAddress).deposit(amount);
        vm.stopPrank();
    }

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mock VVV token
        vvvToken = new MockVVV(owner);

        // Deploy factory via proxy
        factory = deployFactory(address(vvvToken), owner);

        // Mint tokens to users for testing
        vm.startPrank(owner);
        vvvToken.mint(user1, 1000e18);
        vvvToken.mint(user2, 1000e18);
        vvvToken.mint(user3, 1000e18);
        vm.stopPrank();
    }

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
        assertEq(mindContract.owner(), owner);
        assertEq(mindContract.factory(), address(factory));
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
        _depositToMind(user1, mindAddress, depositAmount);

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

        _depositToMind(user1, mindAddress1, deposit1);
        _depositToMind(user2, mindAddress2, deposit2);

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
        _depositToMind(user1, mindAddress, depositAmount);

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

    function testGetTotalContributedBy() public {
        // Create minds
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        // Deposit into mind1
        uint256 deposit1 = 100e18;
        _depositToMind(user1, mindAddress1, deposit1);

        // Deposit into mind2
        uint256 deposit2 = 50e18;
        _depositToMind(user2, mindAddress2, deposit2);

        // Optional burn to ensure contributions persist even after burning
        vm.prank(owner);
        factory.burnFromMind(mindId1);
        vm.prank(owner);
        factory.burnFromMind(mindId2);

        assertEq(factory.getTotalContributedBy(user1), deposit1);
        assertEq(factory.getTotalContributedBy(user2), deposit2);
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

        _depositToMind(user1, mindAddress, amount);

        // Burn from mind
        vm.prank(owner);
        factory.burnFromMind(mindId);

        assertEq(factory.globalTotalBurned(), amount);
        assertEq(factory.getMindTotalBurned(mindId), amount);
    }
}
