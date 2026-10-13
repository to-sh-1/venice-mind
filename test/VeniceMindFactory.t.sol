// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "./MockVVV.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract VeniceMindFactoryV2 is VeniceMindFactory {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract VeniceMindFactoryTest is Test {
    uint256 private constant BASE_TRANSACTION_GAS_CAP = 16_777_216;

    VeniceMindFactory public factory;
    MockVVV public vvvToken;
    address public owner;
    address public burnOperator;
    address public user1;
    address public user2;
    address public user3;

    event MindCreated(address indexed creator, uint256 indexed mindNumber, address indexed mindAddress);
    event GlobalBurn(uint256 indexed mindNumber, uint256 amount, uint256 globalTotal);
    event AllowlistUpdated(address indexed account, bool allowed);
    event AllowlistToggled(bool enabled);
    event MindBurnSkipped(uint256 indexed mindNumber, string reason);
    event BurnOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event MaxCreateBatchSizeUpdated(uint256 previousSize, uint256 newSize);

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
        factory.updateAllowlist(address(this), true);
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

    function testInitialState() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.burnOperator(), burnOperator);
        assertEq(factory.vvvToken(), address(vvvToken));
        assertEq(factory.globalTotalBurned(), 0);
        assertEq(factory.getMindCount(), 0);
        assertEq(factory.allowlistEnabled(), true);
    }

    function testFactoryStartsClosedWithNoImplicitAllowlist() public {
        VeniceMindFactory closedFactory = deployFactory(address(vvvToken), owner);

        assertFalse(closedFactory.allowlist(owner));
        assertFalse(closedFactory.allowlist(user1));

        uint256[] memory mindNumbers = new uint256[](1);
        mindNumbers[0] = 42;
        vm.expectRevert(VeniceMindFactory.NotAllowedToCreateMind.selector);
        vm.prank(user1);
        closedFactory.createMinds(mindNumbers);
    }

    function testCreateMind() public {
        uint256 mindNumber = 42;

        vm.prank(user1);
        address mindAddress = _createMind(factory, mindNumber);

        assertTrue(mindAddress != address(0));
        assertEq(factory.getMindCount(), 1);

        // Check mind info
        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindNumber);
        assertEq(mindInfo.creator, user1);
        assertEq(mindInfo.mindAddress, mindAddress);
        assertEq(mindInfo.createdAt, block.timestamp);
        assertEq(mindInfo.totalBurned, 0);

        // Check that the mind contract is properly initialized
        VeniceMind mindContract = VeniceMind(mindAddress);
        assertEq(mindContract.owner(), owner);
        assertEq(mindContract.factory(), address(factory));
        assertEq(address(mindContract.vvvToken()), address(vvvToken));
    }

    function testCreateMultipleMinds() public {
        vm.prank(user1);
        _createMind(factory, 100);

        vm.prank(user2);
        _createMind(factory, 5);

        assertEq(factory.getMindCount(), 2);

        uint256[] memory mindNumbers = factory.getMindNumbers();
        assertEq(mindNumbers.length, 2);
        assertEq(mindNumbers[0], 100);
        assertEq(mindNumbers[1], 5);

        uint256[] memory page = factory.getMindNumbersPaginated(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], 5);
    }

    function testCreateMindIsDeterministicAndIdempotent() public {
        uint256 mindNumber = 987654;
        bytes memory initData =
            abi.encodeWithSelector(VeniceMind.initialize.selector, address(vvvToken), owner, address(factory));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factory.mindImplementation(), initData))
        );
        address expected = vm.computeCreate2Address(bytes32(mindNumber), initCodeHash, address(factory));

        vm.prank(user1);
        address first = _createMind(factory, mindNumber);
        vm.prank(user2);
        address second = _createMind(factory, mindNumber);

        assertEq(first, expected);
        assertEq(second, first);
        assertEq(factory.getMindCount(), 1);
        assertEq(factory.getMindInfo(mindNumber).creator, user1);
    }

    function testMindNumberZeroIsAnOrdinaryMind() public {
        vm.prank(user1);
        address mindAddress = _createMind(factory, 0);
        vm.prank(user2);
        assertEq(_createMind(factory, 0), mindAddress);

        assertTrue(mindAddress != address(0));
        assertEq(factory.getMindCount(), 1);
        assertEq(factory.getMindNumbers()[0], 0);
        assertEq(factory.getMindInfo(0).creator, user1);

        _depositToMind(user1, mindAddress, 10e18);
        vm.prank(burnOperator);
        factory.burnFromMind(0);
        assertEq(factory.getMindTotalBurned(0), 10e18);
    }

    function testCreateMindsIsAtomicAndIdempotent() public {
        uint256[] memory mindNumbers = new uint256[](3);
        mindNumbers[0] = 10;
        mindNumbers[1] = 20;
        mindNumbers[2] = 10;

        vm.prank(user1);
        address[] memory addresses = factory.createMinds(mindNumbers);

        assertEq(addresses.length, 3);
        assertEq(addresses[0], addresses[2]);
        assertTrue(addresses[0] != addresses[1]);
        assertEq(factory.getMindCount(), 2);
        assertEq(factory.getMindNumbers()[0], 10);
        assertEq(factory.getMindNumbers()[1], 20);
    }

    function testCreateMindsRejectsEmptyInput() public {
        uint256[] memory emptyNumbers = new uint256[](0);

        vm.expectRevert(VeniceMindFactory.EmptyCreateBatch.selector);
        vm.prank(user1);
        factory.createMinds(emptyNumbers);
    }

    function testCreateMindsRejectsAboveMaximumBatchSize() public {
        uint256 length = factory.maxCreateBatchSize() + 1;
        uint256[] memory mindNumbers = new uint256[](length);

        vm.expectRevert(
            abi.encodeWithSelector(VeniceMindFactory.CreateBatchTooLarge.selector, length, factory.maxCreateBatchSize())
        );
        vm.prank(user1);
        factory.createMinds(mindNumbers);
    }

    function testDefaultMaxCreateBatchSize() public view {
        assertEq(factory.maxCreateBatchSize(), factory.DEFAULT_MAX_CREATE_BATCH_SIZE());
        assertEq(factory.maxCreateBatchSize(), 25);
    }

    function testSetMaxCreateBatchSize() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit MaxCreateBatchSizeUpdated(25, 10);
        vm.prank(owner);
        factory.setMaxCreateBatchSize(10);
        assertEq(factory.maxCreateBatchSize(), 10);

        uint256[] memory mindNumbers = new uint256[](11);
        for (uint256 i = 0; i < 11; i++) {
            mindNumbers[i] = i + 1;
        }
        vm.expectRevert(abi.encodeWithSelector(VeniceMindFactory.CreateBatchTooLarge.selector, 11, 10));
        vm.prank(user1);
        factory.createMinds(mindNumbers);
    }

    function testSetMaxCreateBatchSizeRejectsZero() public {
        vm.expectRevert(VeniceMindFactory.ZeroBatchSize.selector);
        vm.prank(owner);
        factory.setMaxCreateBatchSize(0);

        assertEq(factory.maxCreateBatchSize(), factory.DEFAULT_MAX_CREATE_BATCH_SIZE());
    }

    function testSetMaxCreateBatchSizeOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        vm.prank(user1);
        factory.setMaxCreateBatchSize(10);
    }

    function testDefaultMaxBatchFitsBaseTransactionGasCapWithHeadroom() public {
        uint256 transactionGas = _createBatch(factory.maxCreateBatchSize());
        assertLt(transactionGas, (BASE_TRANSACTION_GAS_CAP * 85) / 100);
    }

    function testOwnerCanRaiseBatchSizeAboveDefault() public {
        vm.prank(owner);
        factory.setMaxCreateBatchSize(50);
        assertEq(factory.maxCreateBatchSize(), 50);

        uint256 transactionGas = _createBatch(50);
        assertLt(transactionGas, BASE_TRANSACTION_GAS_CAP);
    }

    function _createBatch(uint256 length) internal returns (uint256 transactionGas) {
        uint256[] memory mindNumbers = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            mindNumbers[i] = i + 1;
        }

        bytes memory callData = abi.encodeCall(VeniceMindFactory.createMinds, (mindNumbers));
        uint256 calldataGas;
        for (uint256 i = 0; i < callData.length; i++) {
            calldataGas += callData[i] == 0 ? 4 : 16;
        }

        vm.prank(user1);
        uint256 gasBefore = gasleft();
        address[] memory mindAddresses = factory.createMinds(mindNumbers);
        transactionGas = gasBefore - gasleft() + 21_000 + calldataGas;

        emit log_named_uint("createMinds transaction gas", transactionGas);
        assertEq(mindAddresses.length, length);
        assertEq(factory.getMindCount(), length);
        assertEq(factory.getMindInfo(1).mindAddress, mindAddresses[0]);
        assertEq(factory.getMindInfo(length).mindAddress, mindAddresses[length - 1]);
    }

    function testBurnFromMind() public {
        // Create a mind
        uint256 mindNumber = 42;
        vm.prank(user1);
        address mindAddress = _createMind(factory, mindNumber);

        // Deposit VVV tokens to the mind
        uint256 depositAmount = 100e18;
        _depositToMind(user1, mindAddress, depositAmount);

        assertEq(factory.getMindVVVBalance(mindNumber), depositAmount);

        // Dedicated burn operator burns from the mind
        vm.expectEmit(true, false, false, true);
        emit GlobalBurn(mindNumber, depositAmount, depositAmount);

        vm.prank(burnOperator);
        factory.burnFromMind(mindNumber);

        assertEq(factory.getMindVVVBalance(mindNumber), 0);
        assertEq(factory.globalTotalBurned(), depositAmount);
        assertEq(factory.getMindTotalBurned(mindNumber), depositAmount);

        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindNumber);
        assertEq(mindInfo.totalBurned, depositAmount);
    }

    function testBurnFromMinds() public {
        // Create multiple minds
        vm.prank(user1);
        address mindAddress1 = _createMind(factory, 100);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, 5);

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
        assertEq(factory.getMindTotalBurned(100), deposit1);
        assertEq(factory.getMindTotalBurned(5), deposit2);
    }

    function testBurnFromMindsPaginated() public {
        vm.prank(user1);
        address mindAddress1 = _createMind(factory, 100);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, 5);

        uint256 deposit1 = 100e18;
        uint256 deposit2 = 50e18;

        _depositToMind(user1, mindAddress1, deposit1);
        _depositToMind(user2, mindAddress2, deposit2);

        // Burn first batch (mind 1 only)
        vm.prank(burnOperator);
        factory.burnFromMinds(0, 1);

        assertEq(factory.globalTotalBurned(), deposit1);
        assertEq(factory.getMindTotalBurned(100), deposit1);
        assertEq(factory.getMindTotalBurned(5), 0);

        // Burn second batch (mind 2 only)
        vm.prank(burnOperator);
        factory.burnFromMinds(1, 1);

        assertEq(factory.globalTotalBurned(), deposit1 + deposit2);
        assertEq(factory.getMindTotalBurned(5), deposit2);
    }

    function testPaginationClampsMaxBatchSize() public {
        vm.prank(user1);
        address mindAddress1 = _createMind(factory, 100);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, 5);

        _depositToMind(user1, mindAddress1, 100e18);
        _depositToMind(user1, mindAddress2, 50e18);

        uint256 max = type(uint256).max;
        uint256[] memory page = factory.getMindNumbersPaginated(1, max);
        assertEq(page.length, 1);
        assertEq(page[0], 5);
        assertEq(factory.getTotalContributedByPaginated(user1, 1, max), 50e18);
        assertEq(factory.getTotalVVVBalancePaginated(1, max), 50e18);

        vm.prank(burnOperator);
        factory.burnFromMinds(1, max);

        assertEq(factory.getMindTotalBurned(100), 0);
        assertEq(factory.getMindTotalBurned(5), 50e18);
        assertEq(factory.globalTotalBurned(), 50e18);
    }

    function testBurnFromMindsEmitsSkippedOnZeroBalance() public {
        vm.prank(user1);
        _createMind(factory, 100);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, 5);

        uint256 deposit2 = 100e18;
        _depositToMind(user2, mindAddress2, deposit2);

        vm.expectEmit(true, false, false, true, address(factory));
        emit MindBurnSkipped(100, "zero balance");

        vm.prank(burnOperator);
        factory.burnFromMinds(0, 2);

        assertEq(factory.globalTotalBurned(), deposit2);
        assertEq(factory.getMindTotalBurned(100), 0);
        assertEq(factory.getMindTotalBurned(5), deposit2);
    }

    function testAllowlist() public {
        vm.prank(owner);
        factory.updateAllowlist(user1, false);

        assertTrue(factory.allowlistEnabled());

        // User1 should not be able to create mind
        vm.expectRevert(VeniceMindFactory.NotAllowedToCreateMind.selector);
        vm.prank(user1);
        _createMind(factory, 42);

        // Add user1 to allowlist
        vm.expectEmit(true, false, false, false);
        emit AllowlistUpdated(user1, true);

        vm.prank(owner);
        factory.updateAllowlist(user1, true);

        assertTrue(factory.allowlist(user1));

        // Now user1 should be able to create mind
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

        assertTrue(mindAddress != address(0));
    }

    function testOnlyBurnOperatorCanBurnFromMind() public {
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

        uint256 depositAmount = 100e18;
        _depositToMind(user1, mindAddress, depositAmount);

        vm.expectRevert(VeniceMindFactory.UnauthorizedBurnOperator.selector);
        vm.prank(owner);
        factory.burnFromMind(42);

        vm.prank(burnOperator);
        factory.burnFromMind(42);
    }

    function testOnlyBurnOperatorCanBurnFromMinds() public {
        vm.prank(user1);
        _createMind(factory, 42);

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
        address mindAddress = _createMind(factory, 42);
        _depositToMind(user1, mindAddress, 100e18);

        address newBurnOperator = makeAddr("newBurnOperator");
        vm.prank(owner);
        factory.setBurnOperator(newBurnOperator);

        vm.expectRevert(VeniceMindFactory.UnauthorizedBurnOperator.selector);
        vm.prank(burnOperator);
        factory.burnFromMind(42);

        vm.prank(newBurnOperator);
        factory.burnFromMind(42);

        assertEq(factory.getMindVVVBalance(42), 0);
        assertEq(factory.globalTotalBurned(), 100e18);
    }

    function testBurnOperatorDoesNotBypassCreationAllowlist() public {
        vm.expectRevert(VeniceMindFactory.NotAllowedToCreateMind.selector);
        vm.prank(burnOperator);
        _createMind(factory, 42);

        vm.prank(owner);
        factory.toggleAllowlist(false);

        vm.prank(burnOperator);
        _createMind(factory, 42);

        assertEq(factory.getMindInfo(42).creator, burnOperator);
    }

    function testBurnOperatorCannotUseOwnerPrivileges() public {
        VeniceMind replacementImplementation = new VeniceMind();
        address mindAddress = _createMind(factory, 42);
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

        vm.expectRevert(VeniceMind.UnauthorizedCaller.selector);
        vm.prank(burnOperator);
        mind.upgradeToAndCall(address(replacementImplementation), "");
    }

    function testOwnerCanBeBurnOperator() public {
        vm.prank(owner);
        factory.setBurnOperator(owner);
        assertEq(factory.burnOperator(), owner);

        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);
        _depositToMind(user1, mindAddress, 100e18);

        vm.prank(owner);
        factory.burnFromMind(42);
        assertEq(factory.getMindTotalBurned(42), 100e18);
        assertEq(factory.globalTotalBurned(), 100e18);
    }

    function testTransferOwnershipToBurnOperator() public {
        vm.prank(owner);
        factory.transferOwnership(burnOperator);
        assertEq(factory.owner(), burnOperator);
        assertEq(factory.burnOperator(), burnOperator);
    }

    function testSetBurnOperatorRejectsZeroAddress() public {
        vm.expectRevert(VeniceMindFactory.ZeroAddress.selector);
        vm.prank(owner);
        factory.setBurnOperator(address(0));
    }

    function testMindTransferredToBurnOperatorDoesNotGrantUpgrade() public {
        address mindAddress = _createMind(factory, 42);
        VeniceMind mind = VeniceMind(mindAddress);

        vm.prank(owner);
        mind.transferOwnership(burnOperator);
        assertEq(mind.owner(), burnOperator);

        VeniceMind replacementImplementation = new VeniceMind();
        vm.expectRevert(VeniceMind.UnauthorizedCaller.selector);
        vm.prank(burnOperator);
        mind.upgradeToAndCall(address(replacementImplementation), "");
    }

    function testFactoryOwnerCanUpgradeMind() public {
        VeniceMind mind = VeniceMind(_createMind(factory, 42));
        _depositToMind(user1, address(mind), 10e18);

        VeniceMind replacementImplementation = new VeniceMind();
        vm.prank(owner);
        mind.upgradeToAndCall(address(replacementImplementation), "");

        assertEq(mind.contributedBy(user1), 10e18);
        assertEq(mind.getVVVBalance(), 10e18);
    }

    function testMindUpgradeAuthorityFollowsFactoryOwnership() public {
        VeniceMind mind = VeniceMind(_createMind(factory, 42));
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        factory.transferOwnership(newOwner);
        assertEq(mind.owner(), owner);

        VeniceMind replacementImplementation = new VeniceMind();
        vm.expectRevert(VeniceMind.UnauthorizedCaller.selector);
        vm.prank(owner);
        mind.upgradeToAndCall(address(replacementImplementation), "");

        vm.prank(newOwner);
        mind.upgradeToAndCall(address(replacementImplementation), "");
    }

    function testMindOwnerCannotUpgradeWithoutFactoryOwnership() public {
        VeniceMind mind = VeniceMind(_createMind(factory, 42));
        address mindOwner = makeAddr("mindOwner");

        vm.prank(owner);
        mind.transferOwnership(mindOwner);

        VeniceMind replacementImplementation = new VeniceMind();
        vm.expectRevert(VeniceMind.UnauthorizedCaller.selector);
        vm.prank(mindOwner);
        mind.upgradeToAndCall(address(replacementImplementation), "");
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
        address mindAddress1 = _createMind(factory, 100);

        vm.prank(user2);
        address mindAddress2 = _createMind(factory, 5);

        // Deposit into mind1
        uint256 deposit1 = 100e18;
        _depositToMind(user1, mindAddress1, deposit1);

        // Deposit into mind2
        uint256 deposit2 = 50e18;
        _depositToMind(user2, mindAddress2, deposit2);

        // Optional burn to ensure contributions persist even after burning
        vm.prank(burnOperator);
        factory.burnFromMind(100);
        vm.prank(burnOperator);
        factory.burnFromMind(5);

        assertEq(factory.getTotalContributedByPaginated(user1, 0, factory.getMindCount()), deposit1);
        assertEq(factory.getTotalContributedByPaginated(user2, 0, factory.getMindCount()), deposit2);
    }

    function testMindOwnerCanEmergencyWithdraw() public {
        // Create a mind
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

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
        address mindAddress = _createMind(factory, 42);

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

    function testInitializeAllowsOwnerAsBurnOperator() public {
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector, address(vvvToken), owner, address(mindImpl), owner
        );

        VeniceMindFactory sameRoleFactory = VeniceMindFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));
        assertEq(sameRoleFactory.owner(), owner);
        assertEq(sameRoleFactory.burnOperator(), owner);
    }

    function testUpgradePreservesCurrentStorage() public {
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);
        vm.prank(owner);
        factory.setMaxCreateBatchSize(10);

        VeniceMindFactoryV2 newImplementation = new VeniceMindFactoryV2();
        vm.prank(owner);
        factory.upgradeToAndCall(address(newImplementation), "");

        VeniceMindFactoryV2 upgradedFactory = VeniceMindFactoryV2(address(factory));
        assertEq(upgradedFactory.version(), 2);
        assertEq(upgradedFactory.owner(), owner);
        assertEq(upgradedFactory.burnOperator(), burnOperator);
        assertEq(upgradedFactory.getMindCount(), 1);
        assertEq(upgradedFactory.getMindInfo(42).mindAddress, mindAddress);
        assertEq(upgradedFactory.getMindInfo(42).creator, user1);
        assertEq(upgradedFactory.maxCreateBatchSize(), 10);
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
        _createMind(factory, 42);

        vm.expectRevert(VeniceMindFactory.ZeroBatchSize.selector);
        vm.prank(burnOperator);
        factory.burnFromMinds(0, 0);
    }

    function testBurnFromMindsStartIndexOutOfBounds() public {
        vm.prank(user1);
        _createMind(factory, 42);

        vm.expectRevert(VeniceMindFactory.StartIndexOutOfBounds.selector);
        vm.prank(burnOperator);
        factory.burnFromMinds(5, 1);
    }

    function testBurnFromMindsClampsEndIndex() public {
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

        uint256 depositAmount = 100e18;
        _depositToMind(user1, mindAddress, depositAmount);

        vm.prank(burnOperator);
        factory.burnFromMinds(0, 99);

        assertEq(factory.globalTotalBurned(), depositAmount);
        assertEq(factory.getMindTotalBurned(42), depositAmount);
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

    function testFuzzCreateMind(uint256 mindNumber) public {
        vm.prank(user1);
        address mindAddress = _createMind(factory, mindNumber);

        assertTrue(mindAddress != address(0));

        VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindNumber);
        assertEq(mindInfo.creator, user1);
        assertEq(mindInfo.mindAddress, mindAddress);
    }

    function testFuzzBurnFromMind(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000000e18);

        // Create a mind
        vm.prank(user1);
        address mindAddress = _createMind(factory, 42);

        // Mint and deposit tokens
        vm.startPrank(owner);
        vvvToken.mint(user1, amount);
        vm.stopPrank();

        _depositToMind(user1, mindAddress, amount);

        // Burn from mind
        vm.prank(burnOperator);
        factory.burnFromMind(42);

        assertEq(factory.globalTotalBurned(), amount);
        assertEq(factory.getMindTotalBurned(42), amount);
    }

    function _createMind(VeniceMindFactory target, uint256 number) internal returns (address) {
        uint256[] memory numbers = new uint256[](1);
        numbers[0] = number;
        address[] memory created = target.createMinds(numbers);
        return created.length == 0 ? address(0) : created[0];
    }
}
