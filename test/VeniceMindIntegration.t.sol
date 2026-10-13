// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "./MockVVV.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VeniceMindIntegrationTest is Test {
    VeniceMindFactory public factory;
    MockVVV public vvvToken;
    address public owner;
    address public burnOperator;
    address public user1;
    address public user2;
    address public user3;
    address public multisig;

    function setUp() public {
        owner = makeAddr("owner");
        burnOperator = makeAddr("burnOperator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        multisig = makeAddr("multisig");

        // Deploy mock VVV token
        vvvToken = new MockVVV(owner);

        // Deploy factory
        factory = deployFactory(address(vvvToken), owner);

        // Mint tokens to users for testing
        vm.startPrank(owner);
        vvvToken.mint(user1, 10000e18);
        vvvToken.mint(user2, 10000e18);
        vvvToken.mint(user3, 10000e18);
        factory.updateAllowlist(user1, true);
        factory.updateAllowlist(user2, true);
        factory.updateAllowlist(user3, true);
        vm.stopPrank();
    }

    function deployFactory(address token, address owner_) internal returns (VeniceMindFactory) {
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector, token, owner_, address(mindImpl), burnOperator
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        return VeniceMindFactory(address(proxy));
    }

    function _depositToMind(address contributor, address mindAddress, uint256 amount) internal {
        vm.startPrank(contributor);
        vvvToken.approve(mindAddress, amount);
        VeniceMind(mindAddress).deposit(amount);
        vm.stopPrank();
    }

    function testFullFlow() public {
        // Step 1: Create minds
        uint256 mindNumber1 = 100;
        uint256 mindNumber2 = 5;
        vm.prank(user1);
        address mindAddress1 = _createMind(factory, mindNumber1);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, mindNumber2);

        assertEq(factory.getMindCount(), 2);

        // Step 2: Multiple users deposit to mind1
        uint256 deposit1a = 100e18;
        uint256 deposit1b = 200e18;
        uint256 deposit1c = 150e18;

        // User1 deposits to mind1
        _depositToMind(user1, mindAddress1, deposit1a);

        // User2 deposits to mind1
        _depositToMind(user2, mindAddress1, deposit1b);

        // User3 deposits to mind1
        _depositToMind(user3, mindAddress1, deposit1c);

        assertEq(factory.getMindVVVBalance(mindNumber1), deposit1a + deposit1b + deposit1c);

        // Step 3: User2 deposits to mind2
        uint256 deposit2 = 300e18;
        _depositToMind(user2, mindAddress2, deposit2);

        assertEq(factory.getMindVVVBalance(mindNumber2), deposit2);

        // Step 4: Dedicated operator burns from mind1
        vm.prank(burnOperator);
        factory.burnFromMind(mindNumber1);

        assertEq(factory.getMindVVVBalance(mindNumber1), 0);
        assertEq(factory.globalTotalBurned(), deposit1a + deposit1b + deposit1c);
        assertEq(factory.getMindTotalBurned(mindNumber1), deposit1a + deposit1b + deposit1c);

        // Step 5: Dedicated operator burns from mind2
        vm.prank(burnOperator);
        factory.burnFromMind(mindNumber2);

        assertEq(factory.getMindVVVBalance(mindNumber2), 0);
        assertEq(factory.globalTotalBurned(), deposit1a + deposit1b + deposit1c + deposit2);
        assertEq(factory.getMindTotalBurned(mindNumber2), deposit2);

        // Step 6: Verify accounting
        assertEq(factory.getTotalVVVBalancePaginated(0, factory.getMindCount()), 0);
        assertEq(factory.globalTotalBurned(), deposit1a + deposit1b + deposit1c + deposit2);
    }

    function testMultipleBurnsPerMind() public {
        // Create a mind
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

        // First deposit and burn
        uint256 deposit1 = 100e18;
        _depositToMind(user1, mindAddress, deposit1);

        vm.prank(burnOperator);
        factory.burnFromMind(42);

        assertEq(factory.globalTotalBurned(), deposit1);
        assertEq(factory.getMindTotalBurned(42), deposit1);

        // Second deposit and burn
        uint256 deposit2 = 200e18;
        _depositToMind(user2, mindAddress, deposit2);

        vm.prank(burnOperator);
        factory.burnFromMind(42);

        assertEq(factory.globalTotalBurned(), deposit1 + deposit2);
        assertEq(factory.getMindTotalBurned(42), deposit1 + deposit2);
    }

    function testBurnFromMinds() public {
        // Create multiple minds
        vm.prank(user1);
        address mindAddress1 = _createMind(factory, 100);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, 5);

        vm.prank(user3);
        address mindAddress3 = _createMind(factory, 999);

        // Deposit to all minds
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 200e18;
        uint256 deposit3 = 300e18;

        _depositToMind(user1, mindAddress1, deposit1);
        _depositToMind(user2, mindAddress2, deposit2);
        _depositToMind(user3, mindAddress3, deposit3);

        assertEq(factory.getTotalVVVBalancePaginated(0, factory.getMindCount()), deposit1 + deposit2 + deposit3);

        // Burn from all minds via paginated call
        vm.prank(burnOperator);
        factory.burnFromMinds(0, 3);

        assertEq(factory.getTotalVVVBalancePaginated(0, factory.getMindCount()), 0);
        assertEq(factory.globalTotalBurned(), deposit1 + deposit2 + deposit3);
        assertEq(factory.getMindTotalBurned(100), deposit1);
        assertEq(factory.getMindTotalBurned(5), deposit2);
        assertEq(factory.getMindTotalBurned(999), deposit3);
    }

    function testOwnershipTransfer() public {
        // Create a mind
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

        VeniceMind mindContract = VeniceMind(mindAddress);
        assertEq(mindContract.owner(), owner);
        assertEq(mindContract.factory(), address(factory));

        // Mind owner (factory owner) transfers ownership directly
        vm.prank(owner);
        mindContract.transferOwnership(multisig);

        assertEq(mindContract.owner(), multisig);

        // Deposit tokens to the mind
        uint256 depositAmount = 100e18;
        _depositToMind(user1, mindAddress, depositAmount);

        // Burns must go through the factory (burn is factory-only)
        vm.prank(burnOperator);
        factory.burnFromMind(42);

        assertEq(mindContract.getVVVBalance(), 0);
        assertEq(mindContract.totalBurned(), depositAmount);
    }

    function testAllowlistFlow() public {
        vm.prank(owner);
        factory.updateAllowlist(user3, false);

        // User1 can create mind (in allowlist)
        vm.prank(user1);
        _createMind(factory, 100);

        // User2 can create mind (in allowlist)
        vm.prank(user2);
        _createMind(factory, 5);

        // User3 cannot create mind (not in allowlist)
        vm.expectRevert(VeniceMindFactory.NotAllowedToCreateMind.selector);
        vm.prank(user3);
        _createMind(factory, 999);

        assertEq(factory.getMindCount(), 2);
    }

    function testEmergencyWithdrawal() public {
        // Create a mind
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

        // Deploy a mock ERC20 token
        MockVVV otherToken = new MockVVV(owner);

        // Mint other tokens to the mind contract
        vm.startPrank(owner);
        otherToken.mint(mindAddress, 100e18);
        vm.stopPrank();

        assertEq(otherToken.balanceOf(mindAddress), 100e18);

        VeniceMind mindContract = VeniceMind(mindAddress);

        // Mind owner (factory owner) performs the withdrawal directly
        vm.prank(owner);
        mindContract.emergencyWithdraw(address(otherToken), multisig);

        assertEq(otherToken.balanceOf(mindAddress), 0);
        assertEq(otherToken.balanceOf(multisig), 100e18);
    }

    function testComplexAccounting() public {
        // Create minds
        vm.prank(user1);
        address mindAddress1 = _createMind(factory, 100);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, 5);

        // Multiple deposits to mind1
        uint256[] memory deposits1 = new uint256[](3);
        deposits1[0] = 100e18;
        deposits1[1] = 200e18;
        deposits1[2] = 150e18;

        address[] memory depositors1 = new address[](3);
        depositors1[0] = user1;
        depositors1[1] = user2;
        depositors1[2] = user3;

        for (uint256 i = 0; i < 3; i++) {
            _depositToMind(depositors1[i], mindAddress1, deposits1[i]);
        }

        // Single deposit to mind2
        uint256 deposit2 = 300e18;
        _depositToMind(user1, mindAddress2, deposit2);

        // Burn from mind1
        vm.prank(burnOperator);
        factory.burnFromMind(100);

        // Burn from mind2
        vm.prank(burnOperator);
        factory.burnFromMind(5);

        // Verify accounting
        uint256 expectedTotal = deposits1[0] + deposits1[1] + deposits1[2] + deposit2;
        assertEq(factory.globalTotalBurned(), expectedTotal);
        assertEq(factory.getMindTotalBurned(100), deposits1[0] + deposits1[1] + deposits1[2]);
        assertEq(factory.getMindTotalBurned(5), deposit2);
        assertEq(factory.getTotalVVVBalancePaginated(0, factory.getMindCount()), 0);
    }

    function _createMind(VeniceMindFactory target, uint256 number) internal returns (address) {
        uint256[] memory numbers = new uint256[](1);
        numbers[0] = number;
        address[] memory created = target.createMinds(numbers);
        return created.length == 0 ? address(0) : created[0];
    }
}
