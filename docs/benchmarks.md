# OMNICOR vs Base / Arbitrum / OP Mainnet — engineering comparison

Method: every OMNICOR number below was **measured on the live devnet**
(chain 420901, 2026-10-05) — see `ops-runbook.md` §20-23 for the exact
procedures. Competitor numbers are from their public docs/blogs (Base
scaling posts, docs.base.org flashblocks, docs.arbitrum.io PGA,
growthepie throughput stats). Devnet measurements are marked **[D]**;
items that only hold on production L1 economics are marked **[P]**.

> **⚠ These numbers are hardware-floored, not ceilinged.** All [D]
> figures come from 4 op-reth instances sharing **8 WSL cores / ~5 GB
> RAM**. Before the Selectel VPS deployment, the full matrix re-runs on
> dedicated hardware — roadmap §Pre-Selectel gate. The gas-limit lever
> (`SystemConfig.setGasLimit` + `--builder.gaslimit`) is live-tunable
> to the 500M protocol ceiling; expect these numbers to go **up**, not
> stay.

## Headline metrics

| Metric | **OMNICOR [D]** | Base | Arbitrum One | OP Mainnet |
|---|---|---|---|---|
| Block time | **1 s** | 2 s | 250 ms (up to 8 blk/s burst) | 2 s |
| Gas limit per second | **200 Mgas/s** | 75 Mgas/s (150M/2s) | ~256 Mgas/s burst ceiling | ~30-60 Mgas/s |
| Peak measured block | **5,001 tx / 105.05 Mgas** | ~3,000+ tx/2s obs. | (no public per-block peak) | ~1,500 tx/2s |
| User-visible tx latency | **~17 ms median accepted** (8-85 ms over 6 samples) | 200 ms flashblock | 250 ms inclusion | 2 s |
| Full inclusion | **~1.5-2.0 s** | 2 s | 250 ms | 2 s |
| Sustained loaded window | **~50 Mgas/s mean, 25 consecutive loaded blocks (59k tx)** | — | — | — |
| Submission throughput | **~2,570 tx/s** (clean pool, 0 retries) | — | — | — |
| Sequencer HA | **3-node Raft** ✅ | single sequencer | single sequencer | single sequencer |
| **Measured leader failover** | **3.2 s to block resume** (2.7 s to election) | unbounded (single seq) | unbounded | unbounded |
| Fault proofs | **full cycle verified live**: proposer+challenger, type-5 permissioned + type-8 CANNON_KONA games created, attacked, resolved (DefenderWins & ChallengerWins) | stage-1 | BoLD permissionless ✅ | stage-1 |
| L2 fee floor | **0 (operatorFee=0, minBaseFee=0)** | market | market | market |

## Where we are ahead today

1. **Throughput per second**: 200 Mgas/s configured limit + measured
   105 Mgas/s *achieved* in a single block — Base's own configured
   ceiling is 75 Mgas/s. We measured a bigger burst than the number they
   report publicly (5,001 tx in one 1-second block vs ~3,000 in 2 s).
2. **Preconfirm latency without the boost pipeline**: the native
   gateway races every ingress endpoint concurrently, returns on the
   first ack and emits `accepted` in **8-85 ms (median ~17 ms)** —
   ~12× faster than Base's 200 ms flashblock cadence, while their
   flashblocks require an external builder stack we don't run
   (NoBoost fallback is documented as the supported local mode).
3. **Sequencer availability — measured, not claimed**: 3-node
   op-conductor Raft. Live kill drill (2026-10-05): cond1 (leader)
   killed under load → cond3 elected in **+2.7 s**, block production
   resumed in **+3.2 s**, exactly one leader, quorum restored to 3/3
   after rejoin. Base, Arbitrum and OP all still run one sequencer
   each — their sequencer outage is unbounded (historically hours).
4. **Fee floor**: `operatorFeeScalar=0`, `minBaseFee=0` — the only cost
   is amortized L1 DA. Same brotli-9 blob batching as the majors.
5. **Fault-proof loop rehearsed end-to-end** (2026-10-05): type-8
   CANNON_KONA games — honest claim left untouched by the challenger,
   bogus claim counter-attacked with the correct honest value
   (`0xb5dd16e6` = output root at the claimed block), full
   resolveClaim→resolve cycle completed yielding **DefenderWins** on the
   honest game and **ChallengerWins** on the bogus one. Challenger runs
   the fresh binary with super/permissioned anchor fixes (#21811,
   #21739, #21681).

## Post-recovery verification matrix (2026-10-05, live)

Full-loop re-verification after the L1 state restore + protocol fixes.
All measurements on the running devnet; `healthcheck.py` reports
11/11 PASS.

| Check | Result |
|---|---|
| unsafe head, all 4 op-nodes | advancing, 1.000 s cadence exactly |
| safe→unsafe gap | 24-30 blocks (batch cadence) |
| finalized heads | advancing on all 4 nodes |
| conductor | exactly 1 leader (cond2), 3/3 voters |
| batcher posting (main + CGT) | active within last L1 block |
| proposer cadence | games every ~60 s (main 752, CGT 252) |
| **spam inclusion** | 500 tx submitted in **132.8 ms (3,765 tx/s)**, all 500 mined in a single block (501-tx block, 10.5 Mgas), 0 retries, pool drained in 4.6 s |
| **preconf gateway** | accepted **106 ms**, confirmed on-chain **1.76 s** (cold-path sample; warm median 17 ms earlier) |
| **withdrawal E2E (CGT, OMNI)** | **complete**: withdrawTo@285038 → game[237] → prove `0x18306a1f` → resolve `0x4ae20fed` → **finalize `0x651c249a` status=1** |
| mempool | all four ELs clean |

### Recovery-era defects fixed this cycle (all in runbook §30-34)

- anvil impersonated-tx `txHash ≠ keccak(RLP)` — poisoned derivation,
  recovered via pre-poison state dump + real signed `setBatcherHash`.
- Proposer cadence froze on future-dated game timestamps (+24 h L1 warp
  legacy) — `op-proposer` now ignores games >1 min in the future.
- Post-Fjord `maxSequencerDrift` was a hardcoded 1800 s — config value
  above the constant now wins; user txs were locked out ~1 day.
- **Portal delays shipped production values (7 d / 3.5 d) despite
  intent.toml 120 s / 60 s** — withdrawals could never finalize.
  Resolved by in-place impl upgrades via ProxyAdmin (storage kept).
- op-reth persists local txs across restarts
  (`txpool-transactions-backup.rlp`) — zombie pool needed the file
  deleted, not a restart.

## Where we are behind (honest list)

1. **Arbitrum 250 ms block time** — OP Stack `BlockTime` is `uint64`
   seconds, so 1 s is the protocol floor today. We counter with the
   220 ms preconf; native sub-second blocks would need a fork change.
2. **BoLD permissionless validation** (Arbitrum) — we run permissioned
   fault proofs (type-5) + live challenger; permissionless CANNON_KONA
   type-8 is the remaining step to parity (see roadmap §Reliability).
3. **Production DA budget [P]**: devnet bursts post everything to anvil
   without cost pressure. On real L1, sustained throughput is bounded by
   purchased blob space (~64 KB/s target across *all* rollups). Our
   500 KB/1 s blocks are a **burst** capability; sustained economics need
   the same blob bidding the majors do. The 200 Mgas config is the
   tested stable point on shared 8-core WSL hardware — on dedicated
   sequencers the same `setGasLimit` path re-measures upward.
4. **Withdrawal latency**: fault-proof withdrawals inherit the standard
   window — devnet now finalizes end-to-end in ~5 min after the
   120 s/60 s intent delays were actually deployed (they were
   mis-deployed at 7 d/3.5 d until 2026-10-05). Production-fast
   withdrawals need the ZK path (roadmap R&D). Open item: L1-side OMNI
   release accounting for unbacked (genesis) L2 supply — §33.

## Verification commands

```bash
# peak block evidence
cast block 258421 --field transactions.length   # 5001
cast block 258421 --field gasUsed               # 105046146
# live config
cast call 0xefd3a1c43086f727fa662cb1672780f461c5d9a7 'gasLimit()(uint64)' \
  --rpc-url http://localhost:9545               # 200000000
# preconf latency
.devnet-tools/preconf/e2e.exe <devnet-key>      # accepted 8-85ms, confirmed ~1.5-2s
# conductor failover drill
taskkill /F /IM op-conductor.exe  # then watch conductor_leader + eth_blockNumber
# measured: leader election +2.7s, block resume +3.2s
```
