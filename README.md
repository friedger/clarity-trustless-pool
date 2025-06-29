# clarity-trustless-pool

Trustless stacking pool on Bitcoin L2 Stacks

The Stacks blockchain's unique Proof of Transfer (PoX) consensus mechanism allows STX holders to earn Bitcoin rewards by participating in stacking already with small amount through stacking pools. However, users have to trust pool operators that they handle the stacking rewards correctly. With **trustless stacking pools** the handling of stacking rewards are now fully managed through smart contracts in a trustless way.

## What is a Trustless Stacking Pool?

A trustless stacking pool is a smart contract system that allows multiple STX holders to combine their tokens for stacking without the need of a pool operator. Trustless pools use sbtc deposits, a smart contract to manage stacking and two smart contracts to distribute rewards.

### Key Benefits

- **No custody risk**: Your STX never leaves your wallet
- **Lower barriers**: Participate with smaller amounts
- **Automated rewards**: Smart contracts handle distribution
- **Transparency**: All operations are on-chain and verifiable

### Risks

- **Smart contract bugs**: Unintentded behaviour encoded in contracts

## Business Rules

The trustless pool should workd according to following rules:

1. Any user can join the pool with at a minimum of 0,0001 base points (~50 STX as of June 2025) of the total locked amount in the current cycle.
2. The pox reward address is defined as the sbtc deposit address of a deposit vault contract.
3. The signer node registers a generic signature for the pox reward address allowing to call commit without signature.
4. Any user can extend the stacking period for other users after half the cycle has passed (only 1 week to revoke delegation for users, can be done by bots)
5. Any user can transfer the stacking rewards from deposit vault to the payout contract during the prepare phase (only first tx would succeed, can be done by bots)
6. Any user can transfer the portion of the rewards assigned to a user from the payout contract to the user. (can be done by bots)
7. Failed sbtc deposits are send to a trusted rewards admin.

Optional rules:

1. Trusted rewards admins can black list payouts for certain users.
2. Users can define a payout address to receive rewards different from the stacking address.

## Architecture Overview

### Contracts

1. **`pox4-self-service-multi.clar`** - Handles delegation and stacking operations
1. **`deposit-vault.clar`** - Holds rewards until the end of the cycle
1. **`payout-self-service-sbtc.clar`** - Manages reward distribution (using sBTC)

```clarity
;; Example stacking call for users
(contract-call? .pox4-self-service-multi delegate-stx
  u1000000000000  ;; amount in micro-STX
  user-data       ;; metadata for rewards
)
```

## Testing Strategy: Flow Tests

Flow tests are crucial for testing complex multi-transaction scenarios that simulate real user interactions. They use special annotations to control transaction senders and test entire workflows.

### Setting Up Flow Tests

Flow tests use comment annotations to specify transaction details:

```clarity
;; @name test the delegation flow
;; @format-ignore
(define-public (test-delegation)
  (begin
    ;; @caller deployer
    (unwrap! (contract-call? .pox4-self-service-multi set-pool-pox-address-active
      {version: 0x00, hashbytes: 0x7321b74e2b6a7e949e6c4ad313035b1665095017})
      (err u1000))
    ;; @caller wallet_1
    (unwrap! (contract-call? 'ST000000000000000000002AMW42H.pox-4
      allow-contract-caller .pox4-self-service-multi none)
      (err u2000))
    ;; More test steps...
    (ok true)
  )
)
```

### Key Testing Patterns

1. **Authorization Flow**: Test that users can properly authorize the pool contract
2. **Delegation Flow**: Verify STX delegation works correctly
3. **Aggregation Flow**: Test that the pool can commit aggregated STX
4. **Reward Distribution**: Ensure rewards are distributed fairly

## Testing Strategy: Devnet

The project contains multiple YAML files for different steps in the stacking cycles:

### 1. Initial Setup (`0-init.yaml`)

```yaml
plan:
  batches:
    - id: 0
      transactions:
        - contract-call:
            contract-id: ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.pox4-self-service-multi
            method: set-pool-pox-address-active
            parameters:
              - "{ hashbytes: 0x7321b74e2b6a7e949e6c4ad313035b1665095017, version: 0x00 }"
```

This deployment:

- Sets up the pool's Bitcoin address for receiving rewards
- Configures initial contract permissions
- Prepares the system for user delegations

### 2. User Delegation (`1-alice-delegate.devnet-plan.yaml`)

```yaml
transactions:
  - contract-call:
      contract-id: ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.pox4-self-service-multi
      expected-sender: ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG
      method: delegate-stx
      parameters:
        - u250000000000000 # 250,000 STX
        - 0x # User data
```

### 3. Aggregation (`2-aggregate-commit-2.yaml`)

User commits the aggregated STX for stacking:

```yaml
transactions:
  - contract-call:
      method: stack-aggregation-commit
      parameters:
        - u2 # Cycle
        - (some 0x18ce215d39a1d3daff...) # Signature
        - 0x03cd2cfdbd2ad9332828a7a13ef... # Signer key
        - u1000000000000000 # Amount
        - u123 # Auth ID
```

### 4. Reward Distribution (`3-distribute-rewards.yaml`)

Finally, rewards are distributed to participants:

```yaml
transactions:
  - contract-call:
      contract-id: ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.payout-self-service-sbtc
      method: distribute-rewards
      parameters:
        - "'ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG" # Recipient
        - u1 # Cycle
```

### Running Devnet Locally

To test the trustless pool on your local devnet:

1. **Start the devnet**:

```bash
clarinet devnet start
```

2. **Deploy contracts**:

```bash
clarinet deployment apply deployments/default.devnet-plan.yaml
```

3. **Run initialization**:

```bash
clarinet deployment apply deployments/0-init.yaml
```

4. **Test user flows**:

```bash
clarinet deployment apply deployments/1-alice-delegate.devnet-plan.yaml
clarinet deployment apply deployments/1-bob-delegate.devnet-plan.yaml
```

## Testing Strategy: Unit tests

To test the trustless pool on simnet with unit tests run the following commands:

```bash
pnpm install
pnpm test
```

## Advanced Testing with Signatures

The pool uses cryptographic signatures to ensure only authorized operations can be performed. The flow tests include signature generation and validation:

```clarity
(define-constant signer-key 0x03cd2cfdbd2ad9332828a7a13ef62cb999e063421c708e863a7ffed71fb61c88c9)

(define-private (aggregate-commit-internal)
  (contract-call? .pox4-self-service-multi
    stack-aggregation-commit
    u0
    (some 0xee088eb40553ca5cddcd7eb18a48f76b5047bfa3b0a3da60446d69226d345c0a49a5a709e74a7a21933fce837e5fee86caaca2dbc4f42391d7710380ad023caf00)
    signer-key
    u1000000000000000
    u123))
```

The signature can be created using script `src/signature.ts`
