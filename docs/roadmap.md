# OMNICOR Engineering Roadmap

Goal: fastest, cheapest, most reliable OP Stack deployment that can be
*proven* — every claim below is tied to a measurable check, not marketing.

## Status snapshot (what exists today)

- Restored upstream OP Stack monorepo @ `02dfabae` + local commit
  `2484e5720a` (benchmark fixes).
- `omnicor/intent.toml` — deployment intent: 1 s block time, 60 Mgas block
  limit (= 60 Mgas/s vs ~15 on Ethereum L1). Devnet currently rehearsing
  120 Mgas (see measured results below).
- `omnicor/contracts/` — full app-layer suite: `OMNICORToken` (fixed 1 B
  supply ERC-20+Permit), `DevVesting` (182d cliff + 4y linear),
  `ReserveVesting` (40 decreasing quarterly tranches, burn-on-expiry),
  `Treasury` (RU/INTL contours, two-step ownership), `OMNIBurner`,
  `FeeSplitter` (hardcoded 70/30 burn/treasury), `SimplePair` (UniV2-subset
  rehearsal AMM), `WOMNI`, `OMNIL1/L2Bridge` (CGT bridging). **73/73
  Foundry tests green; Slither clean** (one real reentrancy-hygiene fix in
  `ReserveVesting._burnExpired` → strict CEI + batched burn transfer).
- `op-node.exe` builds natively; ELs run native op-reth in WSL — the devnet
  no longer requires Docker for the core pipeline (NoBoost mode).
- Measured on devnet (2026-10-05, op-reth + txpool tuning):
  - submission path sustains **~2,795 tx/s** to the sequencer pool;
  - per-block ceiling is the **Jovian DA-footprint cap**
    (`gas_limit / daFootprintGasScalar`, default scalar 400): ~1,500
    minimal txs at 60 Mgas, 3,001 at 120 Mgas — and at **200 Mgas,
    peak block 5,001 tx / 105.05 Mgas (≈105 Mgas/s)**, measured
    concurrently with the blast — the cap is deterministic, so
    throughput scales linearly with the gas limit;
  - EL payload-builder ceiling on 8 shared WSL cores is ≈80–105
    Mgas/s: 400M gas was tested and *lost* to 200M (3,973 tx peak) —
    execution time, not the DA cap, binds first. Sweet spot selected:
    **200 Mgas/block**; dedicated hardware re-measures upward;
  - L2 gas limit upgraded live via `SystemConfig.setGasLimit` (runbook
    §20) — no downtime, 60M → 120M → 200M rehearsed;
  - sequencer HA: 3-node op-conductor Raft, manual + automatic leader
    recovery rehearsed (runbook §12-§19);
  - preconf gateway (`preconf.exe`, native): **accepted ≈ 220 ms,
    confirmed ≈ 1.6 s** after parallel-ingress fix (§22) — competitive
    with Base flashblocks' 200 ms cadence without the external boost
    pipeline (see §C);
  - op-challenger live in WSL against the dispute-game factory (§23) —
    fault-proof loop proposer→challenger covered end-to-end.

### ⚠ Pre-Selectel deployment gate — re-benchmark before going live
The 200 Mgas/block figure is **this machine's ceiling**, not the
network's: on 8 shared WSL cores the EL payload-builder saturates at
≈105 Mgas/s, so 400M was tested and reverted. On the dedicated Selectel
VPS the whole benchmark matrix MUST be re-run before publication:
1. `setGasLimit` ladder 200M → 400M → 500M (protocol ceiling) —
   measure peak tx/block + Mgas/block at each step, settle on the
   highest *stable* value (no missed slots, no FCU timeouts).
2. `--builder.gaslimit` must track the chosen limit on every
   failover-capable EL (runbook §20).
3. Re-measure sustained Mgas/s, tx/s submission, p50/p95/p99 inclusion
   latency and preconf accepted/confirmed — publish only VPS numbers.
4. Re-run at multiple workload types (transfers, storage writes,
   contract calls, mixed) — the DA cap only binds on data-heavy txs;
   compute-heavy txs are EL-bound.
Target: hold the 200 Mgas/s *floor* (already proven) and push toward
the 400-500 Mgas/s band if the hardware allows — do NOT ship the
devnet's WSL-limited numbers as the network's spec sheet.

## Performance levers (ordered by effort/impact)

### A. Configuration — do first, zero code risk
1. `l2BlockTime: 1` — already in intent.toml. Floor is bounded by sequencer
   mempool drain + engine API latency; 1 s is what Base-class chains run.
2. `gasLimit` — **rehearsed live**: 60M → 120M on the devnet via
   `SystemConfig.setGasLimit` + `--builder.gaslimit` bump (runbook §20).
   Proven sustained ~50.7 Mgas/block; the binding ceiling is the Jovian
   DA-footprint cap (`gas_limit / 400` bytes of DA), not compute —
   pick the production limit from the L1 blob-cost budget.
3. `eip1559Denominator`/`ElasticityMultiplier` — tune fee smoothing for the
   higher gas limit.
4. Brotli batch compression (`--batcher.compressor brotli`) — cuts L1 blob
   bytes → cheapest fees at same throughput.
5. `dataAvailabilityType: calldata→blobs` — blobs already default; keep.

### B. Already in-tree, enable in deployment
6. `op-conductor` (Raft leader election + health checks) — sequencer HA;
   eliminates single-sequencer downtime = reliability.
7. `op-dispute-mon` + `op-interop-mon` — fault-proof monitoring.
8. op-reth `pending` block tag streaming — consumers get early state
   (works once any flashblocks stream exists).

### C. Sub-second confirmations — design settled (2026-10 audit)

**Why we do NOT fork consensus block time below 1 s.** L2 timestamps are
u64 *seconds* everywhere: Engine API `payloadAttributes.timestamp`,
derivation (`parent_ts + block_time` in both op-node AND the kona FP
program), span-batch rel_timestamp encoding, EL header monotonicity
(`timestamp > parent.timestamp` in op-reth/op-geth). A "true" 250 ms
consensus block means 4 blocks sharing one timestamp — a deep fork of
the STF, a custom kona prestate, and a permanent upstream-merge burden.
Arbitrum's 250 ms "blocks" are themselves sequencer-signed soft blocks
with no L1 finality — the exact same promise class as a subblock. There
is no honest metric on which 250 ms soft blocks beat 200 ms subblocks.

**The upstream-supported path = subblocks (flashblocks) at 200 ms.**
Producer streams `ExecutionPayloadFlashblockDeltaV1` over WS
(rollup-boost + op-rbuilder, or Enterprise subblocks). Every op-reth
consumer runs `--flashblocks-url <ws>` (+ `--flashblock-consensus` to
drive pending state) and serves `pending` state every 200 ms. Consumer
crate is in-tree and builds in our workspace:
`rust/op-reth/crates/flashblocks/` — `cache.rs:31`
`FLASHBLOCK_BLOCK_TIME = 200` (ms, 5 subblocks per 1 s block).

**OMNICOR latency stack (target, Selectel):**
| Layer | Latency | vs Base | vs Arbitrum | vs OP |
|---|---|---|---|---|
| preconf ack (own gateway) | ~5-20 ms | — | — | — |
| canonical subblock state | 200 ms | = 200 ms | < 250 ms | << 2 s |
| consensus block | 1 s | < 2 s | — | < 2 s |
| L1 batch | ~2-5 min | = | = | = |

= strictly faster user-visible confirmation than all three, plus a
dedicated ack layer none of them ship.

**Selectel checklist:**
1. Producer: rollup-boost + op-rbuilder on the leader EL, behind
   op-conductor (leader change = stream rebuild — rehearse failover).
2. Every EL: `--flashblocks-url` + pending-tag; verify parity across
   l2-a/l2-b/l2-c.
3. Optional, for "beat Base too": patch `FLASHBLOCK_BLOCK_TIME` 200→100 ms
   and run 10 subblocks/block — consumer formula `block_time_ms/200`
   assumes 5/block, must be updated together. Only with our own producer.
4. Verify: e2e subblock stream, pending-tag equality, conductor failover
   mid-sequence, kona/derivation untouched (subblocks are EL-side only —
   no FP impact).
- **Decision needed**: self-host op-rbuilder (fast, upstream-unsupported)
  vs enterprise subblocks (supported, costs) — default: self-host, we
  already carry in-tree patches.

### D. R&D — where "world's fastest" is actually won
1. **Parallel/block-stm execution in op-reth** — partially landed: BAL
   (EIP-7928) parallel execution is already active in our op-reth build
   (`--engine.disable-bal-parallel-execution` exists → enabled by default).
   Remaining: profile per-tx build cost under a saturated pool — at 120M
   gas the block fill is bounded by pool-vs-builder race, so the next
   lever is pool admission and iterator throughput, not raw gas.
2. **Batcher pipeline**: concurrent span-batch assembly, compressor
   saturation metrics — benchmarks now runnable (fixed in `2484e5720a`).
3. **P2P/sequencing**: mempool pre-dedup, engine API latency profiling.
4. **Interop cluster**: shared sequencer set + cross-chain messaging —
   scales horizontally instead of vertically.

## Reliability / security program
- Fault proofs enabled from day 1 (intent.toml `faultProofAbsolutePrestate`,
  challenger + proposer in the deploy set).
  **Status**: proposal pipeline verified end-to-end on the anvil rehearsal —
  op-proposer creating SUPER_PERMISSIONED (type 5) games, anchor updates via
  `setAnchorState`, withdrawal proven+finalized through OptimismPortal, and
  full L2 recovery from L1 batches after total EL state loss.
  Remaining: permissionless CANNON_KONA (type 8) impl + reproducible kona
  prestate for chain 420901, op-challenger, op-dispute-mon.
- Acceptance test suite (`op-acceptance-tests`, `RUST_JIT_BUILD=1`) green
  before any release tag — runs the real contracts + Go + Rust binaries.
- Semgrep + Slither (installed) on `omnicor/contracts` and bedrock diffs.
- Invariant/fuzz tests on `DevVesting` (window boundaries, cliff, reentrancy).
- Deploy rehearsals: devnet → testnet (Sepolia L1) → mainnet; rollback +
  upgrade runbook before any TVL.

## Open questions for the user
1. ~~Vesting schedule~~ — decided: dev 182d cliff + 4y linear; reserve
   40 decreasing quarterly tranches with burn-on-expiry (implemented).
2. 200 ms preconfs: self-hosted op-rbuilder vs no-preconfs vs enterprise?
3. ~~Chain identity~~ — decided: L1 = Ethereum mainnet, OMNI native gas
   token via customGasToken path (implemented).
