// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "./MockVVV.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VeniceMindBurnTest is Test {
    VeniceMind public mindBurn;
    MockVVV public vvvToken;
    address public owner;
    address public user1;
    address public user2;
    address public user3;

    event Burn(address indexed caller, uint256 amount, uint256 totalBurned);
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mock VVV token
        vvvToken = new MockVVV(owner);

        // Deploy upgradeable mind contract
        VeniceMind mindImpl = new VeniceMind();
        bytes memory initData =
            abi.encodeWithSelector(VeniceMind.initialize.selector, address(vvvToken), owner, address(this));
        ERC1967Proxy proxy = new ERC1967Proxy(address(mindImpl), initData);
        mindBurn = VeniceMind(address(proxy));

        // Mint tokens to users for testing
        vm.startPrank(owner);
        vvvToken.mint(user1, 1000e18);
        vvvToken.mint(user2, 1000e18);
        vvvToken.mint(user3, 1000e18);
        vm.stopPrank();
    }

    function _deposit(address contributor, uint256 amount) internal {
        vm.startPrank(contributor);
        vvvToken.approve(address(mindBurn), amount);
        mindBurn.deposit(amount);
        vm.stopPrank();
    }

    function testInitialState() public {
        assertEq(mindBurn.owner(), owner);
        assertEq(address(mindBurn.vvvToken()), address(vvvToken));
        assertEq(mindBurn.totalBurned(), 0);
        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.getContributorCount(), 0);
    }

    function testDepositAndBurn() public {
        uint256 depositAmount = 100e18;

        _deposit(user1, depositAmount);

        assertEq(mindBurn.getVVVBalance(), depositAmount);
        assertEq(mindBurn.totalBurned(), 0);
        assertEq(mindBurn.contributedBy(user1), depositAmount);

        vm.expectEmit(true, false, false, true);
        emit Burn(address(this), depositAmount, depositAmount);

        // Test contract is the factory, so it can call burn()
        mindBurn.burn();

        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.totalBurned(), depositAmount);
        assertEq(mindBurn.contributedBy(user1), depositAmount);
        assertEq(mindBurn.getContributorCount(), 1);
    }

    function testAnonymousTransferIsBurned() public {
        uint256 depositAmount = 100e18;
        uint256 anonymousAmount = 50e18;

        _deposit(user1, depositAmount);

        vm.prank(owner);
        vvvToken.mint(owner, anonymousAmount);
        vm.prank(owner);
        bool success = vvvToken.transfer(address(mindBurn), anonymousAmount);
        assertTrue(success);

        assertEq(vvvToken.balanceOf(address(mindBurn)), depositAmount + anonymousAmount);

        vm.expectEmit(true, false, false, true);
        emit Burn(address(this), depositAmount + anonymousAmount, depositAmount + anonymousAmount);

        mindBurn.burn();

        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.totalBurned(), depositAmount + anonymousAmount);
        assertEq(mindBurn.contributedBy(user1), depositAmount);
    }

    function testBurnWithZeroBalance() public {
        vm.expectRevert(VeniceMind.NoTokensToBurn.selector);
        mindBurn.burn();
    }

    function testOnlyFactoryCanBurn() public {
        uint256 depositAmount = 100e18;

        _deposit(user1, depositAmount);

        vm.expectRevert(VeniceMind.UnauthorizedCaller.selector);
        vm.prank(user1);
        mindBurn.burn();

        vm.expectRevert(VeniceMind.UnauthorizedCaller.selector);
        vm.prank(owner);
        mindBurn.burn();
    }

    function testEmergencyWithdraw() public {
        // Deploy a mock ERC20 token
        MockVVV otherToken = new MockVVV(owner);

        // Mint other tokens to the mind contract
        vm.startPrank(owner);
        otherToken.mint(address(mindBurn), 50e18);
        vm.stopPrank();

        assertEq(otherToken.balanceOf(address(mindBurn)), 50e18);

        // Owner emergency withdraws other tokens
        vm.expectEmit(true, false, true, true);
        emit EmergencyWithdrawal(address(otherToken), 50e18, user1);

        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(otherToken), user1);

        assertEq(otherToken.balanceOf(address(mindBurn)), 0);
        assertEq(otherToken.balanceOf(user1), 50e18);
    }

    function testCannotEmergencyWithdrawVVV() public {
        uint256 depositAmount = 100e18;

        _deposit(user1, depositAmount);

        vm.expectRevert(VeniceMind.CannotWithdrawVVV.selector);
        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(vvvToken), user1);
    }

    function testEmergencyWithdrawZeroAddresses() public {
        vm.expectRevert(VeniceMind.ZeroAddress.selector);
        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(0), user1);

        vm.expectRevert(VeniceMind.ZeroAddress.selector);
        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(vvvToken), address(0));
    }

    function testTransferOwnership() public {
        vm.prank(owner);
        mindBurn.transferOwnership(user1);

        assertEq(mindBurn.owner(), user1);
    }

    function testOnlyOwnerCanTransferOwnership() public {
        vm.expectRevert();
        vm.prank(user1);
        mindBurn.transferOwnership(user2);
    }

    function testGetContributors() public {
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 50e18;

        _deposit(user1, deposit1);
        mindBurn.burn();

        _deposit(user2, deposit2);
        mindBurn.burn();

        address[] memory contributors = mindBurn.getContributorsPaginated(0, mindBurn.getContributorCount());
        assertEq(contributors.length, 2);
        assertEq(contributors[0], user1);
        assertEq(contributors[1], user2);
        assertEq(mindBurn.contributedBy(user1), deposit1);
        assertEq(mindBurn.contributedBy(user2), deposit2);
    }

    function testReentrancyProtection() public {
        uint256 depositAmount = 100e18;

        _deposit(user1, depositAmount);

        mindBurn.burn();
    }

    function testEmergencyWithdrawZeroBalance() public {
        MockVVV otherToken = new MockVVV(owner);

        vm.expectRevert(VeniceMind.NoTokensToWithdraw.selector);
        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(otherToken), user1);
    }

    function testTransferOwnershipToZeroAddress() public {
        vm.expectRevert(VeniceMind.ZeroAddress.selector);
        vm.prank(owner);
        mindBurn.transferOwnership(address(0));
    }

    function testRenounceOwnershipDisabled() public {
        vm.expectRevert(VeniceMind.RenounceOwnershipDisabled.selector);
        vm.prank(owner);
        mindBurn.renounceOwnership();
    }

    function testCannotDoubleInitialize() public {
        vm.expectRevert();
        mindBurn.initialize(address(vvvToken), owner, address(this));
    }

    function testFuzzBurn(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000000e18);

        // Mint tokens to user1
        vm.startPrank(owner);
        vvvToken.mint(user1, amount);
        vm.stopPrank();

        _deposit(user1, amount);

        mindBurn.burn();

        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.totalBurned(), amount);
        assertEq(mindBurn.contributedBy(user1), amount);
    }
}
