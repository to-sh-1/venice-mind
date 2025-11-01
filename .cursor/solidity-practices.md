# Solidity Best Practices Reference

## Security Patterns

### Reentrancy Protection

Always protect functions that make external calls with reentrancy guards:

```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MyContract is ReentrancyGuard {
    function withdraw() external nonReentrant {
        // Safe to transfer
    }
}
```

### Checks-Effects-Interactions

Always follow this pattern:

1. **Checks**: Validate inputs and state
2. **Effects**: Update state variables
3. **Interactions**: Make external calls

```solidity
function transfer(address to, uint256 amount) external {
    // 1. Checks
    require(balance[msg.sender] >= amount, "Insufficient balance");

    // 2. Effects
    balance[msg.sender] -= amount;
    balance[to] += amount;

    // 3. Interactions
    emit Transfer(msg.sender, to, amount);
}
```

### Access Control

Use OpenZeppelin's access control:

```solidity
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MyContract is Ownable {
    function adminFunction() external onlyOwner {
        // Only owner can call
    }
}
```

## Gas Optimization Patterns

### Use Immutable for Constructor-Only Values

```solidity
address public immutable token;
uint256 public immutable maxSupply;

constructor(address _token, uint256 _maxSupply) {
    token = _token;
    maxSupply = _maxSupply;
}
```

### Use Custom Errors

```solidity
// ❌ Bad (expensive)
require(amount > 0, "Amount must be greater than zero");

// ✅ Good (cheap)
error InvalidAmount();
if (amount == 0) revert InvalidAmount();
```

### Cache Storage Reads

```solidity
// ❌ Bad
for (uint256 i = 0; i < users.length; i++) {
    total += balances[users[i]];
}

// ✅ Good
uint256 length = users.length;
for (uint256 i = 0; i < length; i++) {
    total += balances[users[i]];
}
```

### Pack Structs Efficiently

```solidity
// ❌ Bad (2 storage slots)
struct Bad {
    uint128 a;  // slot 1
    uint256 b;  // slot 2 (can't pack)
    uint128 c;  // slot 3
}

// ✅ Good (2 storage slots)
struct Good {
    uint128 a;  // slot 1
    uint128 c;  // slot 1 (packed with a)
    uint256 b;  // slot 2
}
```

## Code Quality Patterns

### Function Visibility

- `external`: Called from outside, most gas efficient
- `public`: Can be called internally or externally
- `internal`: Can be called internally or by derived contracts
- `pure`: No state read/write
- `view`: Reads state but doesn't modify

### Event Patterns

```solidity
event Transfer(
    address indexed from,      // indexed for filtering
    address indexed to,        // indexed for filtering
    uint256 value              // not indexed
);

// Emit with all data
emit Transfer(msg.sender, to, amount);
```

### Error Patterns

```solidity
// Define custom errors
error InsufficientBalance(uint256 required, uint256 available);
error Unauthorized(address account);

// Use with descriptive context
if (balance < amount) {
    revert InsufficientBalance(amount, balance);
}
```

## Testing Patterns

### Foundry Test Structure

```solidity
import {Test, console} from "forge-std/Test.sol";

contract MyTest is Test {
    MyContract public contract;
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    function setUp() public {
        vm.prank(owner);
        contract = new MyContract();
    }

    function testFunction() public {
        vm.prank(user);
        contract.function();

        assertEq(contract.value(), expected);
    }

    function testFuzzFunction(uint256 input) public {
        vm.assume(input > 0 && input < type(uint256).max);

        contract.function(input);

        // Assertions
    }
}
```

### Common Test Utilities

```solidity
// Deal ETH
vm.deal(user, 100 ether);

// Change caller
vm.prank(user);

// Expect revert
vm.expectRevert(MyContract.Unauthorized.selector);

// Expect event
vm.expectEmit(true, false, false, true);
emit Transfer(from, to, amount);

// Time manipulation
vm.warp(block.timestamp + 1 days);
vm.roll(block.number + 1);

// Mock calls
vm.mockCall(token, abi.encodeWithSelector(IERC20.balanceOf.selector, user), abi.encode(100));
```

## Common Pitfalls to Avoid

### Integer Overflow/Underflow

✅ Safe in Solidity 0.8.0+ (automatically checked)
❌ Don't use unchecked blocks unless absolutely necessary

### Delegatecall Dangers

✅ Never use delegatecall with untrusted contracts
✅ Be extremely careful with proxy patterns

### Timestamp Dependence

⚠️ `block.timestamp` can be manipulated by miners (15s window)
✅ Use `block.number` for longer time periods

### Randomness

❌ Never use `block.timestamp`, `block.difficulty`, or `blockhash` for randomness
✅ Use Chainlink VRF or similar oracle solutions

### Front-running

✅ Use commit-reveal schemes for sensitive operations
✅ Consider using private mempools (Flashbots) when applicable

## Naming Conventions

- **Contracts**: `PascalCase` (e.g., `TokenSale`)
- **Functions**: `camelCase` (e.g., `transferTokens`)
- **Variables**: `camelCase` (e.g., `tokenBalance`)
- **Constants**: `UPPER_SNAKE_CASE` (e.g., `MAX_SUPPLY`)
- **Events**: `PascalCase` (e.g., `Transfer`)
- **Errors**: `PascalCase` (e.g., `InsufficientBalance`)
- **Modifiers**: `camelCase` (e.g., `onlyOwner`)

## File Organization

```
contracts/
├── interfaces/
│   └── IMyContract.sol
├── libraries/
│   └── MyLibrary.sol
├── tokens/
│   └── MyToken.sol
└── MyContract.sol

test/
├── MyContract.t.sol
└── integration/
    └── Integration.t.sol

script/
├── Deploy.s.sol
└── Verify.s.sol
```
