// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeniceMindFactory} from "../src/VeniceMindFactory.sol";
import {VeniceMind} from "../src/VeniceMind.sol";
import {MockVVV} from "../src/MockVVV.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @dev Simple ERC20 used as a swap input token in tests
contract MockInputToken is ERC20 {
    constructor() ERC20("Input Token", "INPUT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Simulates a DEX aggregator: takes input token, returns pre-funded VVV
contract MockAggregator {
    IERC20 public inputToken;
    IERC20 public outputToken;
    uint256 public rate; // output per 1e18 input

    constructor(address _inputToken, address _outputToken, uint256 _rate) {
        inputToken = IERC20(_inputToken);
        outputToken = IERC20(_outputToken);
        rate = _rate;
    }

    function swap(uint256 inputAmount) external {
        inputToken.transferFrom(msg.sender, address(this), inputAmount);
        uint256 outputAmount = (inputAmount * rate) / 1e18;
        outputToken.transfer(msg.sender, outputAmount);
    }
}

/// @dev Aggregator that always reverts
contract RevertingAggregator {
    function swap(uint256) external pure {
        revert("swap failed");
    }
}

contract SwapAndDepositTest is Test {
    VeniceMindFactory public factory;
    VeniceMind public mind;
    MockVVV public vvvToken;
    MockInputToken public inputToken;
    MockAggregator public aggregator;

    address public owner;
    address public user1;

    uint256 public mindId;
    address public mindAddress;

    event MindSwapToVVV(
        uint256 indexed mindId,
        address indexed inputToken,
        uint256 inputAmount,
        uint256 vvvReceived,
        address indexed aggregator
    );

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");

        // Deploy tokens (test contract is VVV minter)
        vvvToken = new MockVVV(address(this));
        inputToken = new MockInputToken();

        // Deploy aggregator and pre-fund it with VVV
        aggregator = new MockAggregator(
            address(inputToken),
            address(vvvToken),
            1e18 // 1:1 rate
        );
        vvvToken.mint(address(aggregator), 1_000_000e18);

        // Deploy factory via proxy
        VeniceMind mindImpl = new VeniceMind();
        VeniceMindFactory factoryImpl = new VeniceMindFactory();
        bytes memory initData = abi.encodeWithSelector(
            VeniceMindFactory.initialize.selector,
            address(vvvToken),
            owner,
            address(mindImpl)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = VeniceMindFactory(address(proxy));

        // Create a mind
        vm.prank(user1);
        (mindId, mindAddress) = factory.createMind("Test Mind");
        mind = VeniceMind(mindAddress);

        // Mint input tokens to the mind so swaps source from mind balance
        inputToken.mint(mindAddress, 10_000e18);
    }

    function testSwapAndDepositHappyPath() public {
        uint256 swapAmount = 100e18;

        vm.prank(owner);
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            swapAmount // 1:1 rate, expect full amount
        );

        // VVV should now be in the mind contract
        assertEq(vvvToken.balanceOf(mindAddress), swapAmount);
        // Input token pulled from mind
        assertEq(inputToken.balanceOf(mindAddress), 10_000e18 - swapAmount);
        // Factory holds no residual tokens
        assertEq(vvvToken.balanceOf(address(factory)), 0);
        assertEq(inputToken.balanceOf(address(factory)), 0);
    }

    function testSwapAndDepositEmitsEvent() public {
        uint256 swapAmount = 100e18;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(factory));
        emit MindSwapToVVV(
            mindId,
            address(inputToken),
            swapAmount,
            swapAmount,
            address(aggregator)
        );

        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            swapAmount
        );
    }

    function testSwapAndDepositWithPartialRate() public {
        // Deploy a 50% rate aggregator and fund it
        MockAggregator halfAggregator = new MockAggregator(
            address(inputToken),
            address(vvvToken),
            0.5e18
        );
        vvvToken.mint(address(halfAggregator), 1_000_000e18);

        uint256 swapAmount = 200e18;
        uint256 expectedVVV = 100e18;

        vm.prank(owner);
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(halfAggregator),
            abi.encodeWithSelector(
                MockAggregator.swap.selector,
                swapAmount
            ),
            expectedVVV
        );

        assertEq(vvvToken.balanceOf(mindAddress), expectedVVV);
    }

    function testSwapAndDepositSlippageReverts() public {
        // Deploy a 50% rate aggregator and fund it
        MockAggregator halfAggregator = new MockAggregator(
            address(inputToken),
            address(vvvToken),
            0.5e18
        );
        vvvToken.mint(address(halfAggregator), 1_000_000e18);

        uint256 swapAmount = 100e18;
        uint256 minOut = 100e18; // Expect 100 but only get 50

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(VeniceMind.SlippageExceeded.selector, 50e18, 100e18)
        );
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(halfAggregator),
            abi.encodeWithSelector(
                MockAggregator.swap.selector,
                swapAmount
            ),
            minOut
        );
    }

    function testSwapAndDepositSwapReverts() public {
        RevertingAggregator badAggregator = new RevertingAggregator();

        uint256 swapAmount = 100e18;

        vm.prank(owner);
        vm.expectRevert(VeniceMind.SwapFailed.selector);
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(badAggregator),
            abi.encodeWithSelector(
                RevertingAggregator.swap.selector,
                swapAmount
            ),
            1
        );
    }

    function testSwapAndDepositOnlyOwner() public {
        uint256 swapAmount = 100e18;

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                user1
            )
        );
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            1
        );
        vm.stopPrank();
    }

    function testSwapAndDepositInvalidMind() public {
        uint256 swapAmount = 100e18;

        vm.prank(owner);
        vm.expectRevert(VeniceMindFactory.MindNotFound.selector);
        factory.swapMindToken(
            999,
            address(inputToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            1
        );
    }

    function testSwapAndDepositZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(VeniceMind.ZeroAmount.selector);
        factory.swapMindToken(
            mindId,
            address(inputToken),
            0,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, 0),
            0
        );
    }

    function testSwapAndDepositZeroAggregator() public {
        uint256 swapAmount = 100e18;

        vm.prank(owner);
        vm.expectRevert(VeniceMind.ZeroAddress.selector);
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(0),
            "",
            1
        );
    }

    function testSwapAndDepositCannotSwapFromVVV() public {
        uint256 swapAmount = 100e18;

        vm.prank(owner);
        vm.expectRevert(VeniceMind.CannotSwapFromVVV.selector);
        factory.swapMindToken(
            mindId,
            address(vvvToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            1
        );
    }

    function testSwapAndDepositApprovalsResetAfterSwap() public {
        uint256 swapAmount = 100e18;

        vm.prank(owner);
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            swapAmount
        );

        // Aggregator allowance should be reset to zero on the mind
        assertEq(inputToken.allowance(mindAddress, address(aggregator)), 0);
    }

    function testSwapToVVVOnlyFactory() public {
        uint256 swapAmount = 100e18;

        vm.prank(user1);
        vm.expectRevert(VeniceMind.UnauthorizedCaller.selector);
        mind.swapToVVV(
            address(inputToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            swapAmount
        );
    }

    function testFuzzSwapAndDeposit(uint256 swapAmount) public {
        vm.assume(swapAmount > 0 && swapAmount <= 10_000e18);

        vm.prank(owner);
        factory.swapMindToken(
            mindId,
            address(inputToken),
            swapAmount,
            address(aggregator),
            abi.encodeWithSelector(MockAggregator.swap.selector, swapAmount),
            swapAmount
        );

        assertEq(vvvToken.balanceOf(mindAddress), swapAmount);
        assertEq(inputToken.balanceOf(address(factory)), 0);
        assertEq(vvvToken.balanceOf(address(factory)), 0);
    }
}
