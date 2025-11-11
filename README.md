# Venice Mind Burn Contracts

A master factory and per mind subcontract system that accepts VVV deposits, allows Venice to burn the entire subcontract balance, and keeps accurate accounting per mind and per contributor.

## Architecture

### Master Factory (`VeniceMindFactory`)

- Creates new mind subcontracts using minimal proxy clones for gas savings
- Registry of minds with creator, mind ID, metadata, deployed address, and timestamp
- Global counters of total VVV burned across all minds
- Emits `MindCreated` events
- Can initiate burns across all sub-burn contracts in one transaction
- Optional allowlist for mind creation control

### Mind Subcontract (`VeniceMindBurn`)

- Holds VVV token address fixed at construction
- Accepts VVV deposits
- `burn()` function burns the entire subcontract VVV balance
- Tracks `totalBurned` and cumulative contributions per address (`contributedBy`)
- Owner controls to set or transfer owner to a Venice multisig
- Emergency withdrawal for non-VVV tokens
- Emits `Burn` events with contributor, amount, and running totals

## Features

- **Gas Efficient**: Uses minimal proxy clones for mind creation
- **Secure**: Reentrancy guards, access control, and safe ERC20 handling
- **Flexible**: Optional allowlist for mind creation control
- **Transparent**: Comprehensive event logging and accounting
- **Upgradeable**: Owner can transfer control to multisigs

## Contracts

- `VeniceMindFactory.sol` - Master factory contract
- `VeniceMindBurn.sol` - Mind burn subcontract
- `MockVVV.sol` - Mock VVV token for testing

## Events

- `MindCreated` - Emitted when a new mind is created
- `Burn` - Emitted when VVV tokens are burned
- `OwnerTransferred` - Emitted when ownership is transferred
- `EmergencyWithdrawal` - Emitted when non-VVV tokens are withdrawn
- `GlobalBurn` - Emitted when factory burns from a mind
- `AllowlistUpdated` - Emitted when allowlist is updated

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

```solidity
IERC20 vvvToken = IERC20(vvvTokenAddress);
vvvToken.transfer(mindAddress, amount);
```

### Burning VVV Tokens

```solidity
// Burn from specific mind
factory.burnFromMind(mindId);

// Burn from all minds
factory.burnFromAllMinds();
```

### Transferring Ownership to Multisig

```solidity
factory.transferMindOwnership(mindId, multisigAddress);
```

## Security

- **Access Control**: Only factory owner can burn tokens and manage system
- **Reentrancy Protection**: All burn functions protected against reentrancy
- **Safe ERC20**: Uses OpenZeppelin's SafeERC20 for token operations
- **Emergency Withdrawal**: Can recover non-VVV tokens if needed
- **Input Validation**: Comprehensive parameter validation

## Gas Optimization

- Minimal proxy clones reduce deployment costs
- Batch operations for multiple minds
- Optimized storage layout
- Efficient event emission

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
