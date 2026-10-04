# Relayer & Treasury Runbook

Operational procedures for the backend relayer that submits L2 transactions
on behalf of the business (taxi platform). End users never hold keys.

## Architecture

```text
taxi backend (Go) ──sign/send──► relayer service ──► L2 RPC :8845 (prod: public RPC)
                                     │
                                     ├─ relayer hot key (EOA, working float only,
                                     │  refilled from the treasury Safe)
                                     ├─ nonce manager (per-key, persistent)
                                     ├─ rate limiter + per-contour budgets
                                     └─ audit log → metrics (Prometheus)
```

- One service per contour is recommended (RU contour, INTL contour) —
  separate keys, separate rate limits, separate audit trails. The L2 chain,
  pool, and burn accounting are shared.
- Rationale for relayer over ERC-4337: no user wallets exist; a paymaster
  adds bundler infrastructure for zero benefit. See `integration.md` §6.

## Treasury key

- Dedicated EOA per contour. No other funds; OMNI only (gas) plus the
  business contracts' calldata.
- Hot wallet with hard limits: max tx/day, max OMNI/day, alert at
  20% threshold. Refill procedure:
  1. Buy OMNI ERC-20 on L1 (or withdraw from treasury multisig).
  2. `OMNI.approve(OMNIL1Bridge, amt)` then
     `OMNIL1Bridge.depositTo(relayerEOA, amt, 200_000)`.
  3. Native OMNI lands on the relayer address after L2 derivation
     (~1 L1 confirmation + a few L2 blocks).
- The key never appears in code; load from env/KMS. Rotate on suspicion —
  contracts must not depend on a fixed relayer address (or support
  a `setRelayer` admin path).

## Transaction mechanics

- Chain: L2 chain ID **420902** (rehearsal) / production ID TBD.
- Fees paid in native OMNI automatically — no special tx type; standard
  EIP-1559 fields apply (`maxFeePerGas`, `maxPriorityFeePerGas`).
- Measured cost (rehearsal, near-zero load): transfer ≈ **0.0015 OMNI**,
  contract write ≈ 0.003–0.006 OMNI. Budget with a 10× headroom for
  base-fee spikes.
- Nonce management: track `pending` nonce locally; on restart re-read
  `eth_getTransactionCount(pending)`; never reuse a nonce without
  replacement pricing (+10% min bump).

## Risk controls

- Idempotency: the business payload must carry a unique external ID
  (e.g. ride ID hash) stored/committed on-chain so retries can't
  double-write. Check-before-write on the destination contract.
- Circuit breaker: halt submissions if `eth_gasPrice` > configured cap
  or if L1 data-cost spikes (monitor `l1Fee` on receipts).
- Dead-man switch: treasury multisig can `sweep` nothing — instead keep
  bulk OMNI in the L1 bridge/treasury and only keep a working float
  (~7 days of projected fees) on the hot key.

## Monitoring

| Metric | Source |
|---|---|
| Treasury balance | `eth_getBalance(relayer)` |
| Fee spend/day | sum `gasUsed*effectiveGasPrice` + `l1Fee` on receipts |
| Pending/failed txs | local queue + `eth_getTransactionReceipt` |
| L1→L2 refill latency | `DepositFinalized` events on `OMNIL2Bridge` |
| Pool price drift | `SimplePair.price0()` — sanity-check quote assets |

## Incident playbook

- **Relayer stuck (nonce gap):** resync nonce from `eth_getTransactionCount`;
  cancel stuck txs with 0-value self-sends at higher gas.
- **Treasury drained/leaked:** rotate key immediately; the blast radius is
  bounded by the working float. Audit event log vs on-chain receipts.
- **L2 halt:** queue writes off-chain; replay in order after recovery —
  idempotency keys make replay safe.
