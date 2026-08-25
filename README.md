# Venice Mind Burn Contracts

A master factory and per-mind subcontract system that accepts VVV deposits, allows Venice to burn the entire subcontract balance, and keeps accurate accounting per mind and per contributor.

## Architecture

### Master Factory (`VeniceMindFactory`)

- Creates new mind subcontracts as ERC1967 proxies pointing at a shared `VeniceMind` implementation
- Registry of minds with creator, mind ID, metadata, deployed address, and timestamp
- Global counter of total VVV burned across all minds
- Emits `MindCreated` events
- Burns from a specific mind via `burnFromMind(mindId)`, or from a contiguous window via `burnFromMinds(startIndex, batchSize)`
- Optional allowlist for mind creation control

### Mind Subcontract (`VeniceMind`)

- Holds the VVV token address fixed at initialization
- Accepts VVV deposits through `deposit()`, which records contributor accounting
- `burn()` (factory-only) burns the entire subcontract VVV balance by transferring to `address(0)`
- Tracks `totalBurned` and cumulative contributions per address (`contributedBy`)
- Owner can transfer control to a Venice multisig
- Emergency withdrawal for non-VVV tokens
- Emits `Burn` events with caller, amount, and running totals

## Features

- **Gas Efficient**: Shared implementation plus ERC1967 proxies for mind creation
- **Secure**: Reentrancy guards, access control, and safe ERC20 handling
- **Flexible**: Optional allowlist for mind creation control
- **Transparent**: Comprehensive event logging and accounting
- **Upgradeable**: Factory and minds are UUPS-upgradeable; ownership can move to a multisig

## Contracts

- `src/VeniceMindFactory.sol` - Master factory contract
- `src/VeniceMind.sol` - Mind burn subcontract
- `test/MockVVV.sol` - Mock VVV token for testing (allows transfers to `address(0)`, matching production VVV)

## Events

- `MindCreated` - Emitted when a new mind is created
- `Burn` - Emitted when VVV tokens are burned from a mind
- `OwnershipTransferred` - Emitted when ownership is transferred (OpenZeppelin Ownable)
- `EmergencyWithdrawal` - Emitted when non-VVV tokens are withdrawn
- `GlobalBurn` - Emitted when the factory burns from a mind
- `MindBurnSkipped` - Emitted when a burn is skipped (zero balance, unmanaged mind, or factory check revert)
- `AllowlistUpdated` - Emitted when the allowlist is updated
- `AllowlistToggled` - Emitted when allowlist enforcement is enabled or disabled

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd venice-mind

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Run tests with gas reporting
forge test --gas-report
```

## Testing

The project includes comprehensive tests covering:

- Mind creation and management
- VVV token burning
- Accounting and tracking
- Access control
- Emergency functions
- Integration scenarios
- Fuzz testing

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/VeniceMindBurn.t.sol

# Run with verbose output
forge test -vvv

# Run fuzz tests
forge test --match-test testFuzz
```

## Deployment

### Local Deployment

```bash
# Set up environment variables
export PRIVATE_KEY="your-private-key"

# Deploy to local network
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Testnet/Mainnet Deployment

```bash
# Deploy to testnet
forge script script/Deploy.s.sol --rpc-url $TESTNET_RPC_URL --broadcast --verify

# Verify contracts
forge script script/Verify.s.sol --rpc-url $TESTNET_RPC_URL
```

## Usage

### Creating a Mind

```solidity
VeniceMindFactory factory = VeniceMindFactory(factoryAddress);
(uint256 mindId, address mindAddress) = factory.createMind("My Mind Description");
```

### Depositing VVV Tokens

Call `deposit()` so contributor accounting (`contributedBy`, `contributors`, `totalDeposited`) is updated. A raw `transfer()` still moves tokens into the mind and they can be burned, but it will not be attributed to a contributor.

```solidity
IERC20 vvvToken = IERC20(vvvTokenAddress);
vvvToken.approve(mindAddress, amount);
VeniceMind(mindAddress).deposit(amount);
```

### Burning VVV Tokens

```solidity
// Burn from a specific mind
factory.burnFromMind(mindId);

// Burn from every mind
uint256 count = factory.getMindCount();
factory.burnFromMinds(0, count);
```

### Transferring Ownership to a Multisig

```solidity
VeniceMind mind = VeniceMind(mindAddress);
mind.transferOwnership(multisigAddress);
```

This rotates the **mind** owner only. The factory owner is independent and is not updated. See `ADMIN_GUIDE.md` for the dual-admin model.

### Recovering Non-VVV Tokens

```solidity
VeniceMind mind = VeniceMind(mindAddress);
mind.emergencyWithdraw(tokenAddress, recipientAddress);
```

## Security

- **Dual admin**: Each mind has its own owner (initially the factory owner at creation). The factory owner can still burn and orchestrate swaps through the factory. Rotating the factory owner does not rotate existing mind owners.
- **Burn target**: `burn()` transfers VVV to `address(0)`. Production VVV allows this; a future VVV upgrade that reverts on zero-address transfers would lock burns until minds are upgraded.
- **Access control**: Only the factory owner can burn via the factory, manage the allowlist, change the mind implementation, and upgrade the factory. The mind owner can upgrade that mind, swap via `swapToVVV`, recover non-VVV tokens, and transfer mind ownership.
- **Reentrancy protection**: State-changing entry points that move tokens are protected against reentrancy.
- **Safe ERC20**: Uses OpenZeppelin's SafeERC20 for token operations.
- **Input validation**: Addresses, amounts, and implementation targets are checked before use.

## Gas Optimization

- Shared `VeniceMind` implementation with ERC1967 proxies for new minds
- Batch burns through `burnFromMinds`
- Mind IDs are the contiguous sequence `1 ..= mindCounter` (no redundant ID array)

## License

MIT License

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## Support

For questions or support, please refer to the admin guide (`ADMIN_GUIDE.md`) or open an issue in the repository.
