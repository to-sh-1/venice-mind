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

### 1. Creating Minds

Minds are created through `createMinds`, which takes one or more mind numbers:

```solidity
uint256[] memory mindNumbers = new uint256[](1);
mindNumbers[0] = 42; // number assigned by the external system
address[] memory mindAddresses = factory.createMinds(mindNumbers);
```

**Parameters:**

- `mindNumbers`: External unique numbers for the minds

**Returns:**

- `mindAddresses`: Deployed addresses of the mind proxies, in input order

If a number already exists, the function returns its original address and leaves its creator
and creation-order position unchanged.

**Access:** Only explicitly allowlisted addresses by default. The owner may later disable allowlist
enforcement to make creation public.

The array must be nonempty and is limited to `maxCreateBatchSize()` entries (25 by default). Any number, including 0, is accepted. Existing or repeated numbers resolve to the original address.
Any validation or deployment failure reverts the entire transaction.

The factory owner can change the batch limit to any nonzero value:

```solidity
factory.setMaxCreateBatchSize(newSize);
```

There is no upper bound. Each additional mind costs about 278,000 gas to create (25 measured about
7.0M gas and 50 about 14.0M, including intrinsic and calldata costs), so 60 is the largest batch
that fits under Base's 16,777,216 per-transaction gas cap and 61 or more exceeds it. An oversized batch reverts as a whole and creates nothing, so experiment
by raising the limit gradually, and re-measure on chains with different gas pricing.

### 2. Burning VVV Tokens

#### Burn from a specific mind:

```solidity
factory.burnFromMind(mindNumber);
```

If the mind holds no VVV, the call emits `MindBurnSkipped` with reason `"zero balance"` and returns without reverting.

#### Burn from a window of minds:

```solidity
factory.burnFromMinds(startIndex, batchSize); // a creation-order slice
```

`startIndex` is a 0-based creation-order index, independent of `mindNumber`. If `startIndex + batchSize` exceeds `getMindCount()`, the end is clamped.

Zero-balance minds in the batch emit `MindBurnSkipped` and are skipped; other minds in the window still process.

#### Batch size and Base's gas cap

Base caps each transaction at 16,777,216 gas (EIP-7825), and `burnFromMinds` does not enforce a
window size. Measured cost per mind that holds VVV:

- About 73,400 gas for a mind's first burn (its `totalBurned` goes from zero to nonzero)
- About 39,100 gas for later burns

A single call can therefore process at most about 225 minds in the worst case. Calling
`burnFromMinds(0, getMindCount())` will exceed the cap and revert once the factory has more minds
than that, and nothing is burned in that transaction.

Burn every mind in windows of at most **150** minds (about 11M gas worst case), which leaves
headroom for measurement differences against production VVV and for future mind implementations:

```javascript
const WINDOW = 150n;
const count = await factory.getMindCount();
for (let startIndex = 0n; startIndex < count; startIndex += WINDOW) {
  const estimate = await factory.burnFromMinds.estimateGas(startIndex, WINDOW);
  const tx = await factory.burnFromMinds(startIndex, WINDOW, { gasLimit: (estimate * 13n) / 10n });
  const receipt = await tx.wait();
  const failed = receipt.logs.filter((log) => log.eventName === "MindBurnFailed");
  if (failed.length > 0) {
    // Inspect failed[i].args.reason, then rerun this window
  }
}
```

Each window is an independent transaction. If one reverts, rerun that window; earlier windows
stay burned. Zero-balance minds cost less, so windows that are mostly empty can be larger, but
size windows for the worst case unless you estimate gas first.

#### Gas limits and `MindBurnFailed`

`burnFromMinds` wraps each mind's `burn()` in `try`/`catch`. If the transaction's gas limit is
slightly too low, a mind's `burn()` can run out of gas and be recorded as `MindBurnFailed` (usually
with an empty `reason`) while the transaction as a whole still succeeds. The remaining minds in the
window keep processing or fail the same way.

Gas estimation makes this likely rather than rare: `eth_estimateGas` searches for the lowest gas
limit at which the transaction does not revert, and because caught failures do not revert, that
limit can be one where the last minds in the window fail. Wallets and libraries that send the raw
estimate inherit this.

No VVV is lost. A failed mind keeps its balance, and neither its `totalBurned` nor
`globalTotalBurned` changes, so rerunning the window burns it. The burn operator's tooling should:

- Send `burnFromMinds` with a gas limit well above the estimate (the example above adds 30%)
- Check every receipt for `MindBurnFailed` events and rerun the affected window, or burn those
  minds individually with `burnFromMind`, which does not catch failures and reverts instead
- Treat a `MindBurnFailed` with a non-empty `reason` as a real mind failure to investigate rather
  than a gas problem

**Access:** Only the dedicated burn operator. The burn role itself grants no factory or mind ownership or upgrade permissions.

The factory owner can rotate the operational wallet:

```solidity
factory.setBurnOperator(newBurnOperator);
```

The new operator must be a nonzero address. It may be the factory owner, though a separate operational wallet is recommended in production. The initial operator is set by `initialize` at deployment.

### 3. Depositing VVV (for integrators)

Accounting (`contributedBy`, `contributors`, `totalDeposited`) is updated only through `deposit()`:

```solidity
vvvToken.approve(mindAddress, amount);
VeniceMind(mindAddress).deposit(amount);
```

A raw `vvvToken.transfer(mindAddress, amount)` still credits the mind's VVV balance and can be burned, but it is not attributed to a contributor.

### 4. Managing Individual Minds

Each mind has its own owner, initially set to the **factory owner at the moment of creation**. That owner is independent of later factory-owner rotations. The mind owner controls ownership transfers, `swapToVVV`, and emergency withdrawals:

```solidity
VeniceMind mind = VeniceMind(mindAddress);
mind.transferOwnership(multisigAddress);           // Move control to a multisig
mind.emergencyWithdraw(tokenAddress, recipient);   // Recover non-VVV tokens
mind.swapToVVV(inputToken, amount, aggregator, swapCalldata, minVVVOut);
```

`swapToVVV` is also callable by the factory (`swapMindToken` on the factory forwards to it). The
VVV token itself is rejected as the aggregator, so swap calldata cannot be used to grant VVV
allowances from a mind. Any other token is exposed: the caller chooses the aggregator, calldata, and
`minVVVOut`, so the factory owner can move a mind's non-VVV tokens anywhere through `swapMindToken`,
just as the mind owner can with `emergencyWithdraw`. This holds even after the mind has been
transferred to another owner.

**Access:** Current mind owner (and the factory, for `swapToVVV` only)

#### Upgrading a mind

Mind upgrades are authorized by the **current factory owner**, not by the mind's own owner:

```solidity
VeniceMind(mindAddress).upgradeToAndCall(newImplementation, ""); // sent by factory.owner()
```

Because upgrade authority is read from the factory on every call, transferring factory ownership
moves upgrade control over every existing mind at once. Transferring a mind's ownership does not
grant upgrade rights.

**Access:** Current factory owner

### 5. Allowlist Management

The factory initializes with allowlist enforcement enabled and no implicitly allowed accounts.
Allowlist at least one creator before attempting to create minds.

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

New mind proxies use CREATE2 with `bytes32(mindNumber)` as the salt. The final address also depends
on the factory address, the current implementation, and initializer data such as the current factory
owner. Updating the implementation or transferring factory ownership therefore changes the
counterfactual address of a mind that has not been created yet. Existing mapped minds are unaffected.

## Reading Accounting Data

### Global Statistics

```solidity
uint256 totalBurned = factory.globalTotalBurned();
uint256 mindCount = factory.getMindCount();
```

### Per-Mind Statistics

```solidity
VeniceMindFactory.MindInfo memory mindInfo = factory.getMindInfo(mindNumber);
uint256 mindTotalBurned = factory.getMindTotalBurned(mindNumber);
uint256 mindVVVBalance = factory.getMindVVVBalance(mindNumber);
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

Mind numbers are externally assigned and may be sparse or unordered. The factory stores minds in
creation order for pagination:

```solidity
uint256[] memory mindNumbers = factory.getMindNumbers();
uint256[] memory page = factory.getMindNumbersPaginated(startIndex, batchSize);
```

## Events to Monitor

### MindCreated

```solidity
event MindCreated(
    address indexed creator,
    uint256 indexed mindNumber,
    address indexed mindAddress
);
```

### GlobalBurn

```solidity
event GlobalBurn(
    uint256 indexed mindNumber,
    uint256 amount,
    uint256 globalTotal
);
```

### MindBurnSkipped

```solidity
event MindBurnSkipped(uint256 indexed mindNumber, string reason);
```

Reasons include `"zero balance"`, `"not managed by factory"`, and `"factory check reverted"`.

### AllowlistUpdated

```solidity
event AllowlistUpdated(
    address indexed account,
    bool allowed
);
```

### BurnOperatorUpdated

```solidity
event BurnOperatorUpdated(
    address indexed previousOperator,
    address indexed newOperator
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

### Trust assumption: unburned VVV is recoverable by the factory owner

The factory owner is expected to be a Venice-controlled multisig. That multisig can upgrade every
mind to arbitrary code, so **VVV deposited into a mind is not irreversibly committed until it is
burned**. Until `burnFromMind` or `burnFromMinds` runs, the factory owner could upgrade a mind and
move its VVV elsewhere. Upgrades take effect immediately; the contracts impose no delay.

Depositors and integrators must therefore trust the factory owner not to redirect unburned VVV.
Once VVV has been transferred to `address(0)` by `burn()`, no role can recover it.

Operational expectations:

- The factory owner must be a multisig, never an EOA.
- Factory ownership changes, mind implementation changes, and mind upgrades should be reviewed as
  privileged multisig transactions, with calldata verified independently of the signing UI.
- Burn regularly to keep the amount of unburned VVV under this trust assumption small.

### Authority (burn operator vs factory and mind owners)

The burn operator can initiate individual and batched burns. It cannot manage ownership, implementations, upgrades, swaps, or the creation allowlist.

The factory owner can rotate the burn operator, orchestrate aggregator swaps via `swapMindToken`, manage the allowlist, adjust the creation batch limit, change the implementation used for **new** minds, upgrade the factory itself, and upgrade every mind.

Each mind also has its own owner (initially the factory owner at creation). The mind owner can `emergencyWithdraw` non-VVV tokens, call `swapToVVV`, and `transferOwnership`. The mind owner cannot upgrade the mind.

The contracts do not require the burn operator to differ from the factory owner or from any mind owner. One address can hold every role, which is convenient for testing. In production, keep the burn operator a separate operational wallet: it signs burns frequently, while the factory owner can upgrade every mind and move unburned VVV, so a shared key would put that power on the most exposed wallet.

Ownership identities:

- Mind upgrade authority always follows the **current** factory owner. Transferring factory ownership immediately revokes the previous owner's ability to upgrade any mind.
- Transferring factory ownership does **not** update existing mind owners. A previous factory owner keeps `emergencyWithdraw` (non-VVV only), `swapToVVV`, and `transferOwnership` rights on minds created during their tenure until those minds are transferred.
- Transferring a mind's owner does **not** change the factory owner or burn operator. The burn operator can still burn that mind, and the factory can still call `swapToVVV` through `swapMindToken`, which lets the factory owner move the mind's non-VVV tokens regardless of who owns the mind.

If the factory multisig address changes, also transfer every live mind to the new owner so non-VVV recovery and swap rights move with it.

A faulty mind implementation can disrupt factory-level batch burns. `burnFromMinds` wraps only the `factory()` check and the `burn()` call in `try`/`catch`; a revert there skips that mind. A revert from `getVVVBalance()` or `totalBurned()`, including the `totalBurned()` read after a successful `burn()`, is not caught and reverts the whole window. So does a `totalBurned()` that decreases across `burn()`, or a `factory()` that returns data the factory cannot decode. Review every mind upgrade for compatibility with the factory's burn loop.

### VVV burn target

`VeniceMind.burn()` transfers the full VVV balance to `address(0)`. Production VVV at `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` allows this. Default OpenZeppelin ERC20 does not. A VVV migration or upgrade that re-enables the zero-receiver revert would make every `burn()` call fail and leave VVV locked in minds until the mind implementation is upgraded.

### Other

- Emergency withdrawal only works for non-VVV tokens
- Reentrancy protection is implemented on token-moving entry points
- Access control uses custom errors (see below)

## Gas Optimization

- Shared implementation plus ERC1967 proxies for mind creation
- CREATE2 deployment uses `bytes32(mindNumber)` as the salt
- Atomic creation batches default to 25 entries and the owner can set any nonzero limit; 25 measured about 7.0M gas including intrinsic and calldata costs, and batches of 61 or more exceed Base's 16,777,216 per-transaction gas cap (EIP-7825)
- Batch burning through `burnFromMinds`; about 73,400 gas per mind on its first burn and 39,100 on later burns, so use windows of at most 150 minds to stay under Base's per-transaction gas cap
- Minds are stored in creation order so burn and accounting windows remain paginated

## Error Handling

Common errors and their meanings:

- `MindNotFound`: Invalid or unregistered mind number
- `UnauthorizedCaller`: Caller is neither the mind owner nor the factory (as required), or a mind upgrade was not sent by the current factory owner
- `CannotWithdrawVVV`: Attempted to emergency-withdraw VVV
- `NotAllowedToCreateMind`: Address not on allowlist when enforcement is enabled
- `CreateBatchTooLarge`: `createMinds` called with more than `maxCreateBatchSize()` entries
- `CannotUseVVVAsAggregator`: `swapToVVV` was given the VVV token as the aggregator
- `ZeroBatchSize`: `burnFromMinds` called with `batchSize == 0`, or `setMaxCreateBatchSize` called with zero
- `StartIndexOutOfBounds`: `startIndex` is past the current mind count
- `RenounceOwnershipDisabled`: `renounceOwnership` is not allowed
- `UnauthorizedBurnOperator`: Caller is not the configured burn operator
## Integration Examples

### Web3 Integration

```javascript
// Create a mind
const mindNumber = 42n;
const tx = await factory.createMinds([mindNumber]);
const receipt = await tx.wait();
const event = receipt.logs.find((e) => e.fragment?.name === "MindCreated");
const mindAddress = event.args.mindAddress;

// Deposit through the mind so accounting is recorded
await vvvToken.approve(mindAddress, amount);
await VeniceMind.attach(mindAddress).deposit(amount);

// Burn from one mind
await factory.burnFromMind(mindNumber);

// Burn from every mind in windows that stay under Base's per-transaction gas cap.
// Add a gas buffer and check receipts for MindBurnFailed (see "Gas limits and MindBurnFailed").
const WINDOW = 150n;
const count = await factory.getMindCount();
for (let startIndex = 0n; startIndex < count; startIndex += WINDOW) {
  const estimate = await factory.burnFromMinds.estimateGas(startIndex, WINDOW);
  await factory.burnFromMinds(startIndex, WINDOW, { gasLimit: (estimate * 13n) / 10n });
}

// Transfer mind ownership (mind contract, not factory)
const mind = VeniceMind.attach(mindAddress);
await mind.transferOwnership(multisigAddress);
```

### Monitoring Script

```javascript
const count = await factory.getMindCount();
const pageSize = 100n;
for (let startIndex = 0n; startIndex < count; startIndex += pageSize) {
  const mindNumbers = await factory.getMindNumbersPaginated(startIndex, pageSize);
  for (const mindNumber of mindNumbers) {
    const balance = await factory.getMindVVVBalance(mindNumber);
    const totalBurned = await factory.getMindTotalBurned(mindNumber);
    console.log(`Mind ${mindNumber}: Balance=${balance}, Burned=${totalBurned}`);
  }
}
```
