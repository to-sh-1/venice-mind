# Venice Mind Burn Contracts

A master factory and per-mind subcontract system that accepts VVV deposits, allows Venice to burn the entire subcontract balance, and keeps accurate accounting per mind and per contributor.

## Architecture

### Master Factory (`VeniceMindFactory`)

- Creates new mind subcontracts as ERC1967 proxies pointing at a shared `VeniceMind` implementation
- Registry of minds with externally supplied mind number, creator, deployed address, and timestamp
- Global counter of total VVV burned across all minds
- Emits `MindCreated` events
- Burns from a specific mind via `burnFromMind(mindNumber)`, or from a creation-order window via `burnFromMinds(startIndex, batchSize)`
- Uses a dedicated burn operator role for initiating burns
- Starts with mind creation closed until creator addresses are explicitly allowlisted

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
- **Idempotent**: Repeated creation requests for a mind number resolve to the existing mind
- **Deterministic**: CREATE2 deploys each new mind with `bytes32(mindNumber)` as its salt
- **Flexible**: Atomic batch creation with an owner-adjustable limit (25 by default)
- **Transparent**: Comprehensive event logging and accounting
- **Upgradeable**: Factory and minds are UUPS-upgradeable; all upgrades are authorized by the current factory owner (a multisig)

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
export FACTORY_OWNER_ADDRESS="your-multisig-or-admin-address"
export BURN_OPERATOR_ADDRESS="your-automation-wallet-address"

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

### Creating Minds

```solidity
VeniceMindFactory factory = VeniceMindFactory(factoryAddress);
uint256[] memory mindNumbers = new uint256[](2);
mindNumbers[0] = 42;
mindNumbers[1] = 9001;

address[] memory mindAddresses = factory.createMinds(mindNumbers);
```

The array must be nonempty and contain at most `maxCreateBatchSize()` entries (25 by default; the
owner can set any nonzero limit with `setMaxCreateBatchSize`; batches of 61 or more exceed Base's
per-transaction gas cap and revert). Mind numbers are supplied by the external system, and any value,
including 0, is accepted. Existing or repeated numbers resolve to their original addresses without changing
the creator. Any validation or deployment failure reverts the entire batch. Creation is initially
closed, so the factory owner must explicitly allowlist the caller first.

### Depositing VVV Tokens

Call `deposit()` so contributor accounting (`contributedBy`, `contributors`, `totalDeposited`) is updated. A raw `transfer()` still moves tokens into the mind and they can be burned, but it will not be attributed to a contributor.

```solidity
IERC20 vvvToken = IERC20(vvvTokenAddress);
vvvToken.approve(mindAddress, amount);
VeniceMind(mindAddress).deposit(amount);
```

### Burning VVV Tokens

These calls must be sent by the factory's dedicated `burnOperator`.

```solidity
// Burn from a specific mind
factory.burnFromMind(mindNumber);

// Burn from a creation-order window of minds
factory.burnFromMinds(startIndex, batchSize);
```

Base caps each transaction at 16,777,216 gas. Burning a mind that holds VVV costs about 73,400 gas
the first time and 39,100 afterward, so one call can handle at most about 225 minds. To burn every
mind, loop over windows of at most 150 (`burnFromMinds(0, 150)`, `burnFromMinds(150, 150)`, ...)
instead of calling `burnFromMinds(0, getMindCount())`.

`burnFromMinds` catches each mind's `burn()` failure, so a gas limit that is slightly too low can
make the last minds in a window emit `MindBurnFailed` while the transaction still succeeds. Raw
gas estimates tend to land there. No VVV is lost, but send windows with a gas buffer and rerun any
window whose receipt contains `MindBurnFailed`. See `ADMIN_GUIDE.md` for an example.

### Transferring Ownership to a Multisig

```solidity
VeniceMind mind = VeniceMind(mindAddress);
mind.transferOwnership(multisigAddress);
```

This rotates the **mind** owner only. The factory owner and burn operator are independent and are not updated, and mind upgrades remain with the factory owner. See `ADMIN_GUIDE.md` for the authority model.

### Recovering Non-VVV Tokens

```solidity
VeniceMind mind = VeniceMind(mindAddress);
mind.emergencyWithdraw(tokenAddress, recipientAddress);
```

## Security

- **Trust assumption**: The factory owner (a Venice multisig) can upgrade every mind, so it can recover any VVV that has not been burned yet. Deposits are only irreversible once `burn()` sends them to `address(0)`. See `ADMIN_GUIDE.md`.
- **Burn authority**: Only the burn operator can initiate burns, and the role itself grants no ownership or upgrade authority. The contracts allow the burn operator to be the factory owner (convenient for testing), but production deployments should use a separate operational wallet so the frequently used burn key cannot upgrade minds.
- **Independent ownership**: Each mind has its own owner (initially the factory owner at creation). Rotating the factory owner does not rotate existing mind owners, but it does move upgrade authority over every mind to the new factory owner.
- **Burn target**: `burn()` transfers VVV to `address(0)`. Production VVV allows this; a future VVV upgrade that reverts on zero-address transfers would lock burns until minds are upgraded.
- **Access control**: The factory owner manages the allowlist, burn-operator rotation, mind implementation, swaps through the factory, factory upgrades, and upgrades of every mind. The mind owner can swap via `swapToVVV`, recover non-VVV tokens, and transfer mind ownership, but cannot upgrade the mind.
- **Reentrancy protection**: State-changing entry points that move tokens are protected against reentrancy.
- **Safe ERC20**: Uses OpenZeppelin's SafeERC20 for token operations.
- **Input validation**: Addresses, amounts, and implementation targets are checked before use.
- **Swap aggregator**: `swapToVVV` rejects the VVV token as the aggregator, so swap calldata cannot approve or move a mind's VVV.
- **CREATE2 scope**: A mind address also depends on the factory address, current mind implementation, and initializer data. Changing the implementation or factory owner changes the predicted address of a not-yet-created mind.

## Gas Optimization

- Shared `VeniceMind` implementation with ERC1967 proxies for new minds
- CREATE2 deployment keyed by the externally supplied `mindNumber`
- Atomic creation batches default to 25 and the owner can set any nonzero limit; 25 measured about 7.0M gas including intrinsic and calldata costs, and batches of 61 or more exceed Base's 16,777,216 per-transaction gas cap (EIP-7825)
- Batch burns through `burnFromMinds`, in windows of at most 150 minds to stay under Base's per-transaction gas cap
- Minds remain stored in creation order for paging; mind numbers can be sparse and unordered

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
