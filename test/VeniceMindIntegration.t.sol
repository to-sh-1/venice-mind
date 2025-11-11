// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "../src/MockVVV.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VeniceMindIntegrationTest is Test {
    VeniceMindFactory public factory;
    MockVVV public vvvToken;
    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public multisig;

    function setUp() public {
        owner = makeAddr("owner");
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

    function testFullFlow() public {
        // Step 1: Create minds
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind(
            "Mind 1 - User1"
        );

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind(
            "Mind 2 - User2"
        );

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

        assertEq(
            factory.getMindVVVBalance(mindId1),
            deposit1a + deposit1b + deposit1c
        );

        // Step 3: User2 deposits to mind2
        uint256 deposit2 = 300e18;
        _depositToMind(user2, mindAddress2, deposit2);

        assertEq(factory.getMindVVVBalance(mindId2), deposit2);

        // Step 4: Factory owner burns from mind1
        vm.prank(owner);
        factory.burnFromMind(mindId1);

        assertEq(factory.getMindVVVBalance(mindId1), 0);
        assertEq(
            factory.globalTotalBurned(),
            deposit1a + deposit1b + deposit1c
        );
        assertEq(
            factory.getMindTotalBurned(mindId1),
            deposit1a + deposit1b + deposit1c
        );

        // Step 5: Factory owner burns from mind2
        vm.prank(owner);
        factory.burnFromMind(mindId2);

        assertEq(factory.getMindVVVBalance(mindId2), 0);
        assertEq(
            factory.globalTotalBurned(),
            deposit1a + deposit1b + deposit1c + deposit2
        );
        assertEq(factory.getMindTotalBurned(mindId2), deposit2);

        // Step 6: Verify accounting
        assertEq(factory.getTotalVVVBalance(), 0);
        assertEq(
            factory.globalTotalBurned(),
            deposit1a + deposit1b + deposit1c + deposit2
        );
    }

    function testMultipleBurnsPerMind() public {
        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        // First deposit and burn
        uint256 deposit1 = 100e18;
        _depositToMind(user1, mindAddress, deposit1);

        vm.prank(owner);
        factory.burnFromMind(mindId);

        assertEq(factory.globalTotalBurned(), deposit1);
        assertEq(factory.getMindTotalBurned(mindId), deposit1);

        // Second deposit and burn
        uint256 deposit2 = 200e18;
        _depositToMind(user2, mindAddress, deposit2);

        vm.prank(owner);
        factory.burnFromMind(mindId);

        assertEq(factory.globalTotalBurned(), deposit1 + deposit2);
        assertEq(factory.getMindTotalBurned(mindId), deposit1 + deposit2);
    }

    function testBurnFromAllMinds() public {
        // Create multiple minds
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        vm.prank(user3);
        (uint256 mindId3, address mindAddress3) = factory.createMind("Mind 3");

        // Deposit to all minds
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 200e18;
        uint256 deposit3 = 300e18;

        _depositToMind(user1, mindAddress1, deposit1);
        _depositToMind(user2, mindAddress2, deposit2);
        _depositToMind(user3, mindAddress3, deposit3);

        assertEq(factory.getTotalVVVBalance(), deposit1 + deposit2 + deposit3);

        // Burn from all minds in one transaction
        vm.prank(owner);
        factory.burnFromAllMinds();

        assertEq(factory.getTotalVVVBalance(), 0);
        assertEq(factory.globalTotalBurned(), deposit1 + deposit2 + deposit3);
        assertEq(factory.getMindTotalBurned(mindId1), deposit1);
        assertEq(factory.getMindTotalBurned(mindId2), deposit2);
        assertEq(factory.getMindTotalBurned(mindId3), deposit3);
    }

    function testOwnershipTransfer() public {
        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        VeniceMind mindContract = VeniceMind(mindAddress);
        assertEq(mindContract.owner(), owner);
        assertEq(mindContract.factory(), address(factory));

        // Factory owner transfers ownership to multisig
        vm.prank(owner);
        factory.transferMindOwnership(mindId, multisig);

        assertEq(mindContract.owner(), multisig);

        // Multisig can now control the mind
        uint256 depositAmount = 100e18;
        _depositToMind(user1, mindAddress, depositAmount);

        // Multisig burns the tokens
        vm.prank(multisig);
        mindContract.burn();

        assertEq(mindContract.getVVVBalance(), 0);
        assertEq(mindContract.totalBurned(), depositAmount);
    }

    function testAllowlistFlow() public {
        // Enable allowlist
        vm.prank(owner);
        factory.toggleAllowlist(true);

        // Add users to allowlist
        vm.prank(owner);
        factory.updateAllowlist(user1, true);

        vm.prank(owner);
        factory.updateAllowlist(user2, true);

        // User1 can create mind (in allowlist)
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        // User2 can create mind (in allowlist)
        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

        // User3 cannot create mind (not in allowlist)
        vm.expectRevert(VeniceMindFactory.NotAllowedToCreateMind.selector);
        vm.prank(user3);
        factory.createMind("Mind 3");

        assertEq(factory.getMindCount(), 2);
    }

    function testEmergencyWithdrawal() public {
        // Create a mind
        vm.prank(user1);
        (uint256 mindId, address mindAddress) = factory.createMind("Test Mind");

        // Deploy a mock ERC20 token
        MockVVV otherToken = new MockVVV(owner);

        // Mint other tokens to the mind contract
        vm.startPrank(owner);
        otherToken.mint(mindAddress, 100e18);
        vm.stopPrank();

        assertEq(otherToken.balanceOf(mindAddress), 100e18);

        // Factory owner emergency withdraws other tokens
        vm.prank(owner);
        factory.emergencyWithdrawFromMind(
            mindId,
            address(otherToken),
            multisig
        );

        assertEq(otherToken.balanceOf(mindAddress), 0);
        assertEq(otherToken.balanceOf(multisig), 100e18);
    }

    function testComplexAccounting() public {
        // Create minds
        vm.prank(user1);
        (uint256 mindId1, address mindAddress1) = factory.createMind("Mind 1");

        vm.prank(user2);
        (uint256 mindId2, address mindAddress2) = factory.createMind("Mind 2");

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
        vm.prank(owner);
        factory.burnFromMind(mindId1);

        // Burn from mind2
        vm.prank(owner);
        factory.burnFromMind(mindId2);

        // Verify accounting
        uint256 expectedTotal = deposits1[0] +
            deposits1[1] +
            deposits1[2] +
            deposit2;
        assertEq(factory.globalTotalBurned(), expectedTotal);
        assertEq(
            factory.getMindTotalBurned(mindId1),
            deposits1[0] + deposits1[1] + deposits1[2]
        );
        assertEq(factory.getMindTotalBurned(mindId2), deposit2);
        assertEq(factory.getTotalVVVBalance(), 0);
    }
}
