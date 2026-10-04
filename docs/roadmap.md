# OMNICOR Engineering Roadmap

Goal: fastest, cheapest, most reliable OP Stack deployment that can be
*proven* — every claim below is tied to a measurable check, not marketing.

## Status snapshot (what exists today)

- Restored upstream OP Stack monorepo @ `02dfabae` + local commit
  `2484e5720a` (benchmark fixes).
- `omnicor/intent.toml` — deployment intent: 1 s block time, 60 Mgas block
  limit (= 60 Mgas/s vs ~15 on Ethereum L1).
- `omnicor/contracts/` — `OMNICORToken.sol` (fixed 1 B supply ERC-20+Permit)
  and `DevVesting.sol` (5-year cliff, then ≤10 % of the allocation per rolling
  30 days). 6/6 Foundry tests green.
- `op-node.exe` builds natively; full stack builds need Linux (op-preimage is
  Unix-only upstream) → devnet runs in Docker.

## Performance levers (ordered by effort/impact)

### A. Configuration — do first, zero code risk
1. `l2BlockTime: 1` — already in intent.toml. Floor is bounded by sequencer
   mempool drain + engine API latency; 1 s is what Base-class chains run.
2. `gasLimit 60M` — raise only after benchmarking op-reth at 1 s blocks;
   execution must sustain 60 Mgas/s on target hardware.
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

### C. 200 ms pre-confirmations — the honest picture
- **Subblocks** (current upstream name for flashblocks-style preconfs) are an
  **OP Enterprise feature** — production is not in this repo.
- Legacy **Flashblocks stack** (`rollup-boost` + `op-rbuilder`, external
  repos) can be self-hosted but is officially unsupported; may break at a
  future fork.
- In-tree pieces we keep: op-conductor WS proxy, op-reth `--flashblocks-url`
  consumer, `ExecutionPayloadFlashblockDeltaV1` wire types.
- **Decision needed**: self-host op-rbuilder (fast, risky) vs 1 s blocks
  without preconfs (safe) vs enterprise (expensive, supported).

### D. R&D — where "world's fastest" is actually won
1. **Parallel/block-stm execution in op-reth** — biggest throughput lever
   (Solana-class TPS needs this); gated on reth roadmap. Track upstream reth
   `parallel` work; prototype on a fork before touching production.
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
