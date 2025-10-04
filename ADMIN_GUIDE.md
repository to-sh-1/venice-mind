# Venice Mind Burn System - Admin Guide

## Overview

The Venice Mind Burn system consists of two main contracts:

- **VeniceMindFactory**: Master factory that creates and manages mind burn contracts
- **VeniceMindBurn**: Individual mind contracts that hold and burn VVV tokens

## Contract Addresses

After deployment, you'll have:

- VVV Token: `[VVV_TOKEN_ADDRESS]`
- Factory: `[FACTORY_ADDRESS]`

## Admin Functions

### 1. Creating a Mind

To create a new mind burn contract:

```solidity
// Call createMind on the factory
(uint256 mindId, address mindAddress) = factory.createMind("Mind metadata");
```

**Parameters:**

- `metadata`: Optional string describing the mind

**Returns:**

- `mindId`: Unique ID for the mind
- `mindAddress`: Deployed address of the mind contract

**Access:** Anyone (unless allowlist is enabled)

### 2. Burning VVV Tokens

#### Burn from a specific mind:

```solidity
factory.burnFromMind(mindId);
```

#### Burn from all minds in one transaction:

```solidity
factory.burnFromAllMinds();
```

**Access:** Only factory owner (Venice)

### 3. Transferring Mind Ownership to Multisig

To transfer ownership of a mind to a Venice multisig:

```solidity
factory.transferMindOwnership(mindId, multisigAddress);
```

**Parameters:**

- `mindId`: ID of the mind to transfer
- `multisigAddress`: Address of the multisig

**Access:** Only factory owner (Venice)

### 4. Emergency Withdrawal

To recover non-VVV tokens from a mind:

```solidity
factory.emergencyWithdrawFromMind(mindId, tokenAddress, recipientAddress);
```

**Parameters:**

- `mindId`: ID of the mind
- `tokenAddress`: Address of the token to withdraw
- `recipientAddress`: Address to send tokens to

**Access:** Only factory owner (Venice)

### 5. Allowlist Management

#### Enable/disable allowlist:

```solidity
factory.toggleAllowlist(true);  // Enable
factory.toggleAllowlist(false); // Disable
```

#### Add/remove addresses from allowlist:

```solidity
factory.updateAllowlist(address, true);  // Add
factory.updateAllowlist(address, false); // Remove
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

### Per-Contributor Statistics

```solidity
uint256 contributorTotal = factory.getTotalBurnedBy(contributorAddress);
```

### All Minds

```solidity
uint256[] memory mindIds = factory.getMindIds();
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

### AllowlistUpdated

```solidity
event AllowlistUpdated(
    address indexed account,
    bool allowed
);
```

## Typical Workflow

1. **Deploy System**: Deploy VVV token and factory contracts
2. **Create Minds**: Create mind burn contracts for different purposes
3. **Accept Deposits**: Users deposit VVV tokens to mind contracts
4. **Burn Tokens**: Venice burns VVV tokens from minds (individual or batch)
5. **Transfer Ownership**: Transfer mind ownership to multisigs for decentralized control
6. **Monitor**: Track global and per-mind burn statistics

## Security Considerations

- Only the factory owner (Venice) can burn tokens and manage the system
- Mind contracts are initially owned by the factory
- Ownership can be transferred to multisigs for decentralized control
- Emergency withdrawal only works for non-VVV tokens
- Reentrancy protection is implemented on all burn functions
- Access control prevents unauthorized operations

## Gas Optimization

- Uses minimal proxy clones for gas-efficient mind creation
- Batch burning function reduces gas costs for multiple minds
- Optimized storage layout for efficient reads

## Error Handling

Common errors and their meanings:

- `"Mind does not exist"`: Invalid mind ID
- `"Only mind owner can burn"`: Unauthorized burn attempt
- `"Cannot withdraw VVV tokens"`: Attempted to emergency withdraw VVV
- `"NotAllowedToCreateMind"`: Address not on allowlist when enabled

## Integration Examples

### Web3 Integration

```javascript
// Create a mind
const tx = await factory.createMind("My Mind");
const receipt = await tx.wait();
const event = receipt.events.find((e) => e.event === "MindCreated");
const mindId = event.args.mindId;
const mindAddress = event.args.mindAddress;

// Burn from mind
await factory.burnFromMind(mindId);

// Transfer ownership
await factory.transferMindOwnership(mindId, multisigAddress);
```

### Monitoring Script

```javascript
// Get all minds and their balances
const mindIds = await factory.getMindIds();
for (const mindId of mindIds) {
  const balance = await factory.getMindVVVBalance(mindId);
  const totalBurned = await factory.getMindTotalBurned(mindId);
  console.log(`Mind ${mindId}: Balance=${balance}, Burned=${totalBurned}`);
}
```
