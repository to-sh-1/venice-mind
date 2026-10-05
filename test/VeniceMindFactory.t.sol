// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "./MockVVV.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract VeniceMindFactoryV1Harness is Initializable, OwnableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    address public mindImplementation;
    address public vvvToken;
    uint256 public mindCounter;
    uint256 public globalTotalBurned;
    mapping(address => bool) public allowlist;
    bool public allowlistEnabled;

    struct MindInfo {
        address creator;
        address mindAddress;
        uint256 createdAt;
        uint256 totalBurned;
        string metadata;
    }

    mapping(uint256 => MindInfo) public minds;

    constructor() {
        _disableInitializers();
    }

    function initialize(address token, address initialOwner, address implementation) external initializer {
        __Ownable_init(initialOwner);
        vvvToken = token;
        mindImplementation = implementation;
    }

    function seedState(uint256 counter, uint256 burned, address allowedAccount, uint256 mindId, MindInfo calldata mind)
        external
        onlyOwner
    {
        mindCounter = counter;
        globalTotalBurned = burned;
        allowlist[allowedAccount] = true;
        allowlistEnabled = true;
        minds[mindId] = mind;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[50] private _gap;
}

contract VeniceMindFactoryTest is Test {
    VeniceMindFactory public factory;
    MockVVV public vvvToken;
    address public owner;
    address public burnOperator;
    address public user1;
    address public user2;
    address public user3;

    event MindCreated(address indexed creator, uint256 indexed mindId, address indexed mindAddress, string metadata);
    event GlobalBurn(uint256 indexed mindId, uint256 amount, uint256 globalTotal);
    event AllowlistUpdated(address indexed account, bool allowed);
    event AllowlistToggled(bool enabled);
    event MindBurnSkipped(uint256 indexed mindId, string reason);
    event BurnOperatorUpdated(address indexed previousOperator, address indexed newOperator);

    function _depositToMind(address contributor, address mindAddress, uint256 amount) internal {
        vm.startPrank(contributor);
        vvvToken.approve(mindAddress, amount);
        VeniceMind(mindAddress).deposit(amount);
        vm.stopPrank();
    }

    function setUp() public {
        owner = makeAddr("owner");
        burnOperator = makeAddr("burnOperator");
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

    function deployFactory(address token, address owner_) internal returns (VeniceMindFactory) {
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector, token, owner_, address(mindImpl), burnOperator
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        return VeniceMindFactory(address(proxy));
    }

    function testInitialState() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.burnOperator(), burnOperator);
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
        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindId);
        assertEq(mindInfo.creator, user1);
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
        (uint256 mindId1,) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2,) = factory.createMind("Mind 2");

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

        // Dedicated burn operator burns from the mind
        vm.expectEmit(true, false, false, true);
        emit GlobalBurn(mindId, depositAmount, depositAmount);

        vm.prank(burnOperator);
        factory.burnFromMind(mindId);

        assertEq(factory.getMindVVVBalance(mindId), 0);
        assertEq(factory.globalTotalBurned(), depositAmount);
        assertEq(factory.getMindTotalBurned(mindId), depositAmount);

        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindId);
        assertEq(mindInfo.totalBurned, depositAmount);
    }

    function testBurnFromMinds() public {
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

        assertEq(factory.getTotalVVVBalancePaginated(0, factory.getMindCount()), deposit1 + deposit2);

        // Dedicated burn operator burns from all minds via pagination
        vm.prank(burnOperator);
        factory.burnFromMinds(0, 2);

        assertEq(factory.getTotalVVVBalancePaginated(0, factory.getMindCount()), 0);
        assertEq(factory.globalTotalBurned(), deposit1 + deposit2);
        assertEq(factory.getMindTotalBurned(mindId1), deposit1);
        assertEq(factory.getMindTotalBurned(mindId2), deposit2);
    }

    function testBurnFromMindsPaginated() public {
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        uint256 deposit1 = 100e18;
        uint256 deposit2 = 50e18;

        _depositToMind(user1, mindAddress1, deposit1);
        _depositToMind(user2, mindAddress2, deposit2);

        // Burn first batch (mind 1 only)
        vm.prank(burnOperator);
        factory.burnFromMinds(0, 1);

        assertEq(factory.globalTotalBurned(), deposit1);
        assertEq(factory.getMindTotalBurned(mindId1), deposit1);
        assertEq(factory.getMindTotalBurned(mindId2), 0);

        // Burn second batch (mind 2 only)
        vm.prank(burnOperator);
        factory.burnFromMinds(1, 1);

        assertEq(factory.globalTotalBurned(), deposit1 + deposit2);
        assertEq(factory.getMindTotalBurned(mindId2), deposit2);
    }

    function testBurnFromMindsEmitsSkippedOnZeroBalance() public {
        vm.prank(user1);
        (uint256 mindId1,) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        uint256 deposit2 = 100e18;
        _depositToMind(user2, mindAddress2, deposit2);

        vm.expectEmit(true, false, false, true, address(factory));
        emit MindBurnSkipped(mindId1, "zero balance");

        vm.prank(burnOperator);
        factory.burnFromMinds(0, 2);

        assertEq(factory.globalTotalBurned(), deposit2);
        assertEq(factory.getMindTotalBurned(mindId1), 0);
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

    function testOnlyBurnOperatorCanBurnFromMind() public {
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        uint256 depositAmount = 100e18;
        _depositToMind(user1, mindAddress, depositAmount);

        vm.expectRevert(VeniceMindFactory.UnauthorizedBurnOperator.selector);
        vm.prank(owner);
        factory.burnFromMind(mindId);

        vm.prank(burnOperator);
        factory.burnFromMind(mindId);
    }

    function testOnlyBurnOperatorCanBurnFromMinds() public {
        vm.prank(user1);
        factory.createMind("Mind 1");

        vm.expectRevert(VeniceMindFactory.UnauthorizedBurnOperator.selector);
        vm.prank(owner);
        factory.burnFromMinds(0, 1);
    }

    function testOwnerCanRotateBurnOperator() public {
        address newBurnOperator = makeAddr("newBurnOperator");

        vm.expectEmit(true, true, false, true);
        emit BurnOperatorUpdated(burnOperator, newBurnOperator);

        vm.prank(owner);
        factory.setBurnOperator(newBurnOperator);

        assertEq(factory.burnOperator(), newBurnOperator);
    }

    function testRotatingBurnOperatorRevokesOldOperatorAndEnablesNewOperator() public {
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Operator rotation");
        _depositToMind(user1, mindAddress, 100e18);

        address newBurnOperator = makeAddr("newBurnOperator");
        vm.prank(owner);
        factory.setBurnOperator(newBurnOperator);

        vm.expectRevert(VeniceMindFactory.UnauthorizedBurnOperator.selector);
        vm.prank(burnOperator);
        factory.burnFromMind(mindId);

        vm.prank(newBurnOperator);
        factory.burnFromMind(mindId);

        assertEq(factory.getMindVVVBalance(mindId), 0);
        assertEq(factory.globalTotalBurned(), 100e18);
    }

    function testBurnOperatorDoesNotBypassCreationAllowlist() public {
        vm.prank(owner);
        factory.toggleAllowlist(true);

        vm.expectRevert(VeniceMindFactory.NotAllowedToCreateMind.selector);
        vm.prank(burnOperator);
        factory.createMind("Not allowlisted");

        vm.prank(owner);
        factory.toggleAllowlist(false);

        vm.prank(burnOperator);
        (uint256 mindId,) = factory.createMind("Public creation");

        assertEq(factory.getMindInfo(mindId).creator, burnOperator);
    }

    function testBurnOperatorCannotUseOwnerPrivileges() public {
        VeniceMind replacementImplementation = new VeniceMind();
        (, address mindAddress) = factory.createMind("Permission separation");
        VeniceMind mind = VeniceMind(mindAddress);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, burnOperator));
        vm.prank(burnOperator);
        factory.setMindImplementation(address(replacementImplementation));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, burnOperator));
        vm.prank(burnOperator);
        factory.transferOwnership(user1);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, burnOperator));
        vm.prank(burnOperator);
        mind.transferOwnership(user1);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, burnOperator));
        vm.prank(burnOperator);
        mind.upgradeToAndCall(address(replacementImplementation), "");
    }

    function testBurnOperatorMustDifferFromOwner() public {
        vm.expectRevert(VeniceMindFactory.BurnOperatorMustDifferFromOwner.selector);
        vm.prank(owner);
        factory.setBurnOperator(owner);

        vm.expectRevert(VeniceMindFactory.BurnOperatorMustDifferFromOwner.selector);
        vm.prank(owner);
        factory.transferOwnership(burnOperator);
    }

    function testSetBurnOperatorRejectsZeroAddress() public {
        vm.expectRevert(VeniceMindFactory.ZeroAddress.selector);
        vm.prank(owner);
        factory.setBurnOperator(address(0));
    }

    function testMindCanBeExplicitlyTransferredToBurnOperator() public {
        (, address mindAddress) = factory.createMind("Explicit overlap");
        VeniceMind mind = VeniceMind(mindAddress);

        vm.prank(owner);
        mind.transferOwnership(burnOperator);

        VeniceMind replacementImplementation = new VeniceMind();
        vm.prank(burnOperator);
        mind.upgradeToAndCall(address(replacementImplementation), "");

        assertEq(mind.owner(), burnOperator);
    }

    function testFuzzFactoryOwnerAndBurnOperatorRemainDistinct(address newBurnOperator, address newOwner) public {
        vm.assume(newBurnOperator != address(0));
        vm.assume(newBurnOperator != owner);
        vm.assume(newOwner != address(0));
        vm.assume(newOwner != newBurnOperator);

        vm.prank(owner);
        factory.setBurnOperator(newBurnOperator);

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        assertEq(factory.owner(), newOwner);
        assertEq(factory.burnOperator(), newBurnOperator);
        assertTrue(factory.owner() != factory.burnOperator());
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
        vm.prank(burnOperator);
        factory.burnFromMind(mindId1);
        vm.prank(burnOperator);
        factory.burnFromMind(mindId2);

        assertEq(factory.getTotalContributedByPaginated(user1, 0, factory.getMindCount()), deposit1);
        assertEq(factory.getTotalContributedByPaginated(user2, 0, factory.getMindCount()), deposit2);
    }

    function testMindOwnerCanEmergencyWithdraw() public {
        // Create a mind
        vm.prank(user1);
        (, address mindAddress) = factory.createMind("Test Mind");

        // Deploy a mock ERC20 token
        MockVVV otherToken = new MockVVV(owner);

        // Mint other tokens to the mind contract
        vm.startPrank(owner);
        otherToken.mint(mindAddress, 50e18);
        vm.stopPrank();

        assertEq(otherToken.balanceOf(mindAddress), 50e18);

        // Mind owner (factory owner) emergency withdraws other tokens directly
        VeniceMind mindContract = VeniceMind(mindAddress);
        vm.prank(owner);
        mindContract.emergencyWithdraw(address(otherToken), user1);

        assertEq(otherToken.balanceOf(mindAddress), 0);
        assertEq(otherToken.balanceOf(user1), 50e18);
    }

    function testOnlyOwnerCanEmergencyWithdraw() public {
        vm.prank(user1);
        (, address mindAddress) = factory.createMind("Test Mind");

        MockVVV otherToken = new MockVVV(owner);

        vm.startPrank(owner);
        otherToken.mint(mindAddress, 50e18);
        vm.stopPrank();

        VeniceMind mindContract = VeniceMind(mindAddress);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        vm.prank(user1);
        mindContract.emergencyWithdraw(address(otherToken), user1);
    }

    function testBurnFromNonExistentMind() public {
        vm.expectRevert(VeniceMindFactory.MindNotFound.selector);
        vm.prank(burnOperator);
        factory.burnFromMind(999);
    }

    function testGetMindInfoNonExistent() public view {
        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(999);
        assertEq(mindInfo.mindAddress, address(0));
    }

    function testRenounceOwnershipDisabled() public {
        vm.expectRevert(VeniceMindFactory.RenounceOwnershipDisabled.selector);
        vm.prank(owner);
        factory.renounceOwnership();
    }

    function testCannotDoubleInitializeFactory() public {
        VeniceMind mindImpl = new VeniceMind();
        vm.expectRevert();
        factory.initialize(address(vvvToken), owner, address(mindImpl), burnOperator);
    }

    function testInitializeRejectsZeroBurnOperator() public {
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector, address(vvvToken), owner, address(mindImpl), address(0)
        );

        vm.expectRevert(VeniceMindFactory.ZeroAddress.selector);
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function testInitializeRejectsOwnerAsBurnOperator() public {
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector, address(vvvToken), owner, address(mindImpl), owner
        );

        vm.expectRevert(VeniceMindFactory.BurnOperatorMustDifferFromOwner.selector);
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function testUpgradeToAndCallSetsBurnOperatorAndPreservesStorage() public {
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactoryV1Harness v1Implementation = new VeniceMindFactoryV1Harness();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactoryV1Harness.initialize.selector, address(vvvToken), owner, address(mindImpl)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(v1Implementation), initData);
        VeniceMindFactoryV1Harness v1Factory = VeniceMindFactoryV1Harness(address(proxy));

        VeniceMindFactoryV1Harness.MindInfo memory legacyMind = VeniceMindFactoryV1Harness.MindInfo({
            creator: user1, mindAddress: user2, createdAt: 1234, totalBurned: 55e18, metadata: "legacy mind"
        });
        vm.prank(owner);
        v1Factory.seedState(7, 99e18, user3, 1, legacyMind);

        VeniceMindFactory newImplementation = new VeniceMindFactory();
        bytes memory migrationCall = abi.encodeCall(VeniceMindFactory.setBurnOperator, (burnOperator));
        vm.prank(owner);
        v1Factory.upgradeToAndCall(address(newImplementation), migrationCall);

        VeniceMindFactory upgradedFactory = VeniceMindFactory(address(proxy));
        VeniceMindFactory.MindInfo memory migratedMind = upgradedFactory.getMindInfo(1);
        assertEq(upgradedFactory.owner(), owner);
        assertEq(upgradedFactory.burnOperator(), burnOperator);
        assertEq(upgradedFactory.vvvToken(), address(vvvToken));
        assertEq(upgradedFactory.mindImplementation(), address(mindImpl));
        assertEq(upgradedFactory.mindCounter(), 7);
        assertEq(upgradedFactory.globalTotalBurned(), 99e18);
        assertTrue(upgradedFactory.allowlistEnabled());
        assertTrue(upgradedFactory.allowlist(user3));
        assertEq(migratedMind.creator, legacyMind.creator);
        assertEq(migratedMind.mindAddress, legacyMind.mindAddress);
        assertEq(migratedMind.createdAt, legacyMind.createdAt);
        assertEq(migratedMind.totalBurned, legacyMind.totalBurned);
        assertEq(migratedMind.metadata, legacyMind.metadata);
    }

    function testSetMindImplementationZeroAddress() public {
        vm.expectRevert(VeniceMindFactory.ZeroAddress.selector);
        vm.prank(owner);
        factory.setMindImplementation(address(0));
    }

    function testSetMindImplementationNotContract() public {
        vm.expectRevert(VeniceMindFactory.InvalidImplementation.selector);
        vm.prank(owner);
        factory.setMindImplementation(makeAddr("eoa"));
    }

    function testBurnFromMindsZeroBatchSize() public {
        vm.prank(user1);
        factory.createMind("Mind 1");

        vm.expectRevert(VeniceMindFactory.ZeroBatchSize.selector);
        vm.prank(burnOperator);
        factory.burnFromMinds(0, 0);
    }

    function testBurnFromMindsStartIndexOutOfBounds() public {
        vm.prank(user1);
        factory.createMind("Mind 1");

        vm.expectRevert(VeniceMindFactory.StartIndexOutOfBounds.selector);
        vm.prank(burnOperator);
        factory.burnFromMinds(5, 1);
    }

    function testBurnFromMindsClampsEndIndex() public {
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Mind 1");

        uint256 depositAmount = 100e18;
        _depositToMind(user1, mindAddress, depositAmount);

        vm.prank(burnOperator);
        factory.burnFromMinds(0, 99);

        assertEq(factory.globalTotalBurned(), depositAmount);
        assertEq(factory.getMindTotalBurned(mindId), depositAmount);
    }

    function testSwapMindTokenNonExistentMind() public {
        vm.expectRevert(VeniceMindFactory.MindNotFound.selector);
        vm.prank(owner);
        factory.swapMindToken(999, address(vvvToken), 100, address(1), "", 0);
    }

    function testGetMindVVVBalanceNonExistentMind() public {
        vm.expectRevert(VeniceMindFactory.MindNotFound.selector);
        factory.getMindVVVBalance(999);
    }

    function testFuzzCreateMind(string calldata metadata) public {
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind(metadata);

        assertEq(mindId, 1);
        assertTrue(mindAddress != address(0));

        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindId);
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
        vm.prank(burnOperator);
        factory.burnFromMind(mindId);

        assertEq(factory.globalTotalBurned(), amount);
        assertEq(factory.getMindTotalBurned(mindId), amount);
    }
}
