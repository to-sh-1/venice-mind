# Venice Mind Burn System - Admin Guide

## Overview

The Venice Mind Burn system consists of two main contracts:

- **VeniceMindFactory**: Master factory that creates and manages mind burn contracts
- **VeniceMind**: Individual mind contracts that hold and burn VVV tokens

Minds are deployed as ERC1967 proxies pointing at a shared `VeniceMind` implementation set on the factory.

## Contract Addresses

After deployment, you'll have:

- VVV Token: `[VVV_TOKEN_ADDRESS]` (production: `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf`)
- Factory: `[FACTORY_ADDRESS]`

## Admin Functions

### 1. Creating a Mind

To create a new mind burn contract:

```solidity
(uint256 mindId, address mindAddress) = factory.createMind("Mind metadata");
```

**Parameters:**

- `metadata`: Optional string describing the mind

**Returns:**

- `mindId`: Unique ID for the mind (contiguous sequence starting at 1)
- `mindAddress`: Deployed address of the mind proxy

**Access:** Anyone (unless allowlist is enabled)

### 2. Burning VVV Tokens

#### Burn from a specific mind:

```solidity
factory.burnFromMind(mindId);
```

If the mind holds no VVV, the call emits `MindBurnSkipped` with reason `"zero balance"` and returns without reverting.

#### Burn from a window of minds:

```solidity
uint256 count = factory.getMindCount();
factory.burnFromMinds(0, count);       // every mind
factory.burnFromMinds(startIndex, batchSize); // a contiguous slice
```

`startIndex` is 0-based (`startIndex=0` is mind ID 1). If `startIndex + batchSize` exceeds `getMindCount()`, the end is clamped. To burn every mind, pass `startIndex=0` and `batchSize=getMindCount()`.

Zero-balance minds in the batch emit `MindBurnSkipped` and are skipped; other minds in the window still process.

**Access:** Only factory owner (Venice)

### 3. Depositing VVV (for integrators)

Accounting (`contributedBy`, `contributors`, `totalDeposited`) is updated only through `deposit()`:

```solidity
vvvToken.approve(mindAddress, amount);
VeniceMind(mindAddress).deposit(amount);
```

A raw `vvvToken.transfer(mindAddress, amount)` still credits the mind's VVV balance and can be burned, but it is not attributed to a contributor.

### 4. Managing Individual Minds

Each mind has its own owner, initially set to the **factory owner at the moment of creation**. That owner is independent of later factory-owner rotations. The mind owner (not the factory) controls ownership transfers, upgrades of that mind, `swapToVVV`, and emergency withdrawals:

```solidity
VeniceMind mind = VeniceMind(mindAddress);
mind.transferOwnership(multisigAddress);           // Move control to a multisig
mind.emergencyWithdraw(tokenAddress, recipient);   // Recover non-VVV tokens
mind.swapToVVV(inputToken, amount, aggregator, swapCalldata, minVVVOut);
```

`swapToVVV` is also callable by the factory (`swapMindToken` on the factory forwards to it).

**Access:** Current mind owner (and the factory, for `swapToVVV` only)

### 5. Allowlist Management

#### Enable/disable allowlist:

```solidity
factory.toggleAllowlist(true);  // Enable
factory.toggleAllowlist(false); // Disable
```

#### Add/remove addresses from allowlist:

```solidity
factory.updateAllowlist(account, true);  // Add
factory.updateAllowlist(account, false); // Remove
```

**Access:** Only factory owner (Venice)

### 6. Mind Implementation

New minds use the implementation currently stored on the factory. Updating it does not upgrade already-deployed minds.

```solidity
factory.setMindImplementation(newImplementation);
```

**Access:** Only factory owner (Venice)

## Reading Accounting Data

### Global Statistics

```solidity
uint256 totalBurned = factory.globalTotalBurned();
uint256 mindCount = factory.getMindCount();
```

### Per-Mind Statistics

```solidity
VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindId);
uint256 mindTotalBurned = factory.getMindTotalBurned(mindId);
uint256 mindVVVBalance = factory.getMindVVVBalance(mindId);
```

### Per-Contributor Statistics (Paginated)

```solidity
uint256 count = factory.getMindCount();
uint256 contributorTotal = factory.getTotalContributedByPaginated(contributorAddress, 0, count);
```

### Aggregate VVV Balance (Paginated)

```solidity
uint256 count = factory.getMindCount();
uint256 totalBalance = factory.getTotalVVVBalancePaginated(0, count);
```

### All Minds

Mind IDs are the contiguous sequence `1 ..= getMindCount()`. `getMindIds()` synthesizes that list; prefer pagination for large sets:

```solidity
uint256[] memory mindIds = factory.getMindIds();
uint256[] memory page = factory.getMindIdsPaginated(startIndex, batchSize);
```

## Events to Monitor

### MindCreated

```solidity
event MindCreated(
    address indexed creator,
    uint256 indexed mindId,
    address indexed mindAddress,
    string metadata
);
```

### GlobalBurn

```solidity
event GlobalBurn(
    uint256 indexed mindId,
    uint256 amount,
    uint256 globalTotal
);
```

### MindBurnSkipped

```solidity
event MindBurnSkipped(uint256 indexed mindId, string reason);
```

Reasons include `"zero balance"`, `"not managed by factory"`, and `"factory check reverted"`.

### AllowlistUpdated

```solidity
event AllowlistUpdated(
    address indexed account,
    bool allowed
);
```

## Typical Workflow

1. **Deploy System**: Deploy the `VeniceMind` implementation, then the factory proxy, pointing at production VVV
2. **Create Minds**: Create mind burn contracts for different purposes
3. **Accept Deposits**: Users `approve` + `deposit` VVV into mind contracts
4. **Burn Tokens**: Venice burns VVV from minds (individual or batched window)
5. **Transfer Ownership**: Transfer mind ownership to a multisig if desired
6. **Monitor**: Track global and per-mind burn statistics

## Security Considerations

### Dual admin (factory owner vs mind owner)

The factory owner can burn from any mind, orchestrate aggregator swaps via `swapMindToken`, manage the allowlist, change the implementation used for **new** minds, and upgrade the factory itself.

Each mind also has its own owner (initially the factory owner at creation). The mind owner can `emergencyWithdraw` non-VVV tokens, call `swapToVVV`, upgrade that mind, and `transferOwnership`.

These identities drift independently:

- Transferring factory ownership does **not** update existing mind owners. A previous factory owner keeps upgrade and recovery rights on every mind created during their tenure unless those minds are transferred or upgraded separately.
- Transferring a mind's owner does **not** change the factory owner. The factory can still burn that mind and call `swapToVVV` through `swapMindToken`.

If the factory key is rotated, also transfer (or upgrade) every live mind, or accept that the previous owner retains mind-level authority.

A malicious mind implementation can disrupt factory-level batch burns (for example by reverting on `factory()` inside `burnFromMinds`). Treat a compromised mind owner as able to interfere with factory operations that iterate minds.

### VVV burn target

`VeniceMind.burn()` transfers the full VVV balance to `address(0)`. Production VVV at `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` allows this. Default OpenZeppelin ERC20 does not. A VVV migration or upgrade that re-enables the zero-receiver revert would make every `burn()` call fail and leave VVV locked in minds until the mind implementation is upgraded.

### Other

- Emergency withdrawal only works for non-VVV tokens
- Reentrancy protection is implemented on token-moving entry points
- Access control uses custom errors (see below)

## Gas Optimization

- Shared implementation plus ERC1967 proxies for mind creation
- Batch burning through `burnFromMinds`
- Mind IDs derived from `mindCounter` rather than a redundant stored array

## Error Handling

Common errors and their meanings:

- `MindNotFound`: Invalid or unregistered mind ID
- `UnauthorizedCaller`: Caller is neither the mind owner nor the factory (as required)
- `CannotWithdrawVVV`: Attempted to emergency-withdraw VVV
- `NotAllowedToCreateMind`: Address not on allowlist when enforcement is enabled
- `ZeroBatchSize`: `burnFromMinds` called with `batchSize == 0`
- `StartIndexOutOfBounds`: `startIndex` is past the current mind count
- `RenounceOwnershipDisabled`: `renounceOwnership` is not allowed

## Integration Examples

### Web3 Integration

```javascript
// Create a mind
const tx = await factory.createMind("My Mind");
const receipt = await tx.wait();
const event = receipt.logs.find((e) => e.fragment?.name === "MindCreated");
const mindId = event.args.mindId;
const mindAddress = event.args.mindAddress;

// Deposit through the mind so accounting is recorded
await vvvToken.approve(mindAddress, amount);
await VeniceMind.attach(mindAddress).deposit(amount);

// Burn from one mind
await factory.burnFromMind(mindId);

// Burn from every mind
const count = await factory.getMindCount();
await factory.burnFromMinds(0, count);

// Transfer mind ownership (mind contract, not factory)
const mind = VeniceMind.attach(mindAddress);
await mind.transferOwnership(multisigAddress);
```

### Monitoring Script

```javascript
const count = await factory.getMindCount();
for (let i = 0; i < count; i++) {
  const mindId = i + 1n;
  const balance = await factory.getMindVVVBalance(mindId);
  const totalBurned = await factory.getMindTotalBurned(mindId);
  console.log(`Mind ${mindId}: Balance=${balance}, Burned=${totalBurned}`);
}
```
