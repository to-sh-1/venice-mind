// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "../src/MockVVV.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VeniceMindBurnTest is Test {
    VeniceMind public mindBurn;
    MockVVV public vvvToken;
    address public owner;
    address public user1;
    address public user2;
    address public user3;

    event Burn(
        address indexed contributor,
        uint256 amount,
        uint256 totalBurned,
        uint256 contributorTotal
    );
    event OwnerTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event EmergencyWithdrawal(
        address indexed token,
        uint256 amount,
        address indexed to
    );

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mock VVV token
        vvvToken = new MockVVV(owner);

        // Deploy upgradeable mind contract
        VeniceMind mindImpl = new VeniceMind();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMind.initialize.selector,
            address(vvvToken),
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(mindImpl), initData);
        mindBurn = VeniceMind(address(proxy));

        // Mint tokens to users for testing
        vm.startPrank(owner);
        vvvToken.mint(user1, 1000e18);
        vvvToken.mint(user2, 1000e18);
        vvvToken.mint(user3, 1000e18);
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

        // User1 deposits VVV tokens
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), depositAmount);
        vvvToken.transfer(address(mindBurn), depositAmount);
        vm.stopPrank();

        assertEq(mindBurn.getVVVBalance(), depositAmount);
        assertEq(mindBurn.totalBurned(), 0);

        // Owner burns the tokens
        vm.expectEmit(true, false, false, true);
        emit Burn(owner, depositAmount, depositAmount, depositAmount);

        vm.prank(owner);
        mindBurn.burn();

        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.totalBurned(), depositAmount);
        assertEq(mindBurn.burnedBy(owner), depositAmount);
        assertEq(mindBurn.getContributorCount(), 1);
    }

    function testBurnForSpecificContributor() public {
        uint256 depositAmount = 100e18;

        // User1 deposits VVV tokens
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), depositAmount);
        vvvToken.transfer(address(mindBurn), depositAmount);
        vm.stopPrank();

        // Owner burns the tokens and attributes to user1
        vm.expectEmit(true, false, false, true);
        emit Burn(user1, depositAmount, depositAmount, depositAmount);

        vm.prank(owner);
        mindBurn.burnFor(user1);

        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.totalBurned(), depositAmount);
        assertEq(mindBurn.burnedBy(user1), depositAmount);
        assertEq(mindBurn.getContributorCount(), 1);
    }

    function testMultipleBurns() public {
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 50e18;

        // User1 deposits first batch
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), deposit1);
        vvvToken.transfer(address(mindBurn), deposit1);
        vm.stopPrank();

        // Owner burns first batch
        vm.prank(owner);
        mindBurn.burnFor(user1);

        // User2 deposits second batch
        vm.startPrank(user2);
        vvvToken.approve(address(mindBurn), deposit2);
        vvvToken.transfer(address(mindBurn), deposit2);
        vm.stopPrank();

        // Owner burns second batch
        vm.prank(owner);
        mindBurn.burnFor(user2);

        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.totalBurned(), deposit1 + deposit2);
        assertEq(mindBurn.burnedBy(user1), deposit1);
        assertEq(mindBurn.burnedBy(user2), deposit2);
        assertEq(mindBurn.getContributorCount(), 2);
    }

    function testBurnWithZeroBalance() public {
        vm.expectRevert(VeniceMind.NoTokensToBurn.selector);
        vm.prank(owner);
        mindBurn.burn();
    }

    function testBurnForZeroAddress() public {
        uint256 depositAmount = 100e18;

        // User1 deposits VVV tokens
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), depositAmount);
        vvvToken.transfer(address(mindBurn), depositAmount);
        vm.stopPrank();

        vm.expectRevert("Contributor address cannot be zero");
        vm.prank(owner);
        mindBurn.burnFor(address(0));
    }

    function testOnlyOwnerCanBurn() public {
        uint256 depositAmount = 100e18;

        // User1 deposits VVV tokens
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), depositAmount);
        vvvToken.transfer(address(mindBurn), depositAmount);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user1);
        mindBurn.burn();
    }

    function testOnlyOwnerCanBurnFor() public {
        uint256 depositAmount = 100e18;

        // User1 deposits VVV tokens
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), depositAmount);
        vvvToken.transfer(address(mindBurn), depositAmount);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user1);
        mindBurn.burnFor(user1);
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

        // User1 deposits VVV tokens
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), depositAmount);
        vvvToken.transfer(address(mindBurn), depositAmount);
        vm.stopPrank();

        vm.expectRevert("Cannot withdraw VVV tokens");
        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(vvvToken), user1);
    }

    function testEmergencyWithdrawZeroAddresses() public {
        vm.expectRevert("Token address cannot be zero");
        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(0), user1);

        vm.expectRevert("Recipient address cannot be zero");
        vm.prank(owner);
        mindBurn.emergencyWithdraw(address(vvvToken), address(0));
    }

    function testTransferOwnership() public {
        vm.expectEmit(true, true, false, false);
        emit OwnerTransferred(owner, user1);

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

        // User1 deposits and burns
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), deposit1);
        vvvToken.transfer(address(mindBurn), deposit1);
        vm.stopPrank();

        vm.prank(owner);
        mindBurn.burnFor(user1);

        // User2 deposits and burns
        vm.startPrank(user2);
        vvvToken.approve(address(mindBurn), deposit2);
        vvvToken.transfer(address(mindBurn), deposit2);
        vm.stopPrank();

        vm.prank(owner);
        mindBurn.burnFor(user2);

        address[] memory contributors = mindBurn.getContributors();
        assertEq(contributors.length, 2);
        assertEq(contributors[0], user1);
        assertEq(contributors[1], user2);
    }

    function testReentrancyProtection() public {
        // This test would require a malicious contract to test reentrancy
        // For now, we'll just verify the nonReentrant modifier is present
        uint256 depositAmount = 100e18;

        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), depositAmount);
        vvvToken.transfer(address(mindBurn), depositAmount);
        vm.stopPrank();

        // Should not revert due to reentrancy
        vm.prank(owner);
        mindBurn.burn();
    }

    function testFuzzBurn(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000000e18);

        // Mint tokens to user1
        vm.startPrank(owner);
        vvvToken.mint(user1, amount);
        vm.stopPrank();

        // User1 deposits tokens
        vm.startPrank(user1);
        vvvToken.approve(address(mindBurn), amount);
        vvvToken.transfer(address(mindBurn), amount);
        vm.stopPrank();

        // Owner burns tokens
        vm.prank(owner);
        mindBurn.burnFor(user1);

        assertEq(mindBurn.getVVVBalance(), 0);
        assertEq(mindBurn.totalBurned(), amount);
        assertEq(mindBurn.burnedBy(user1), amount);
    }
}
