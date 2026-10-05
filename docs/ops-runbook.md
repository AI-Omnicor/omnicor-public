# OMNICOR Ops Runbook

Devnet topology, failure modes observed in production drills, and the recovery
procedures that were actually used to restore the chain.

## Topology (chain 420901)

| Component | Endpoint | Role |
|---|---|---|
| anvil L1 | :9545 http, :5052 beacon-shim | L1 (devnet) |
| EL A/B/C (op-reth, WSL) | http :8645/:8745/:8945, auth :8651/:8751/:8951 | execution |
| op-node A/B/T | rpc :9647/:9747/:10047 | consensus+sequencer candidates |
| op-node F | rpc :11047, engine 9551 (builder A) | verifier/follower |
| op-conductor 1/2/3 | rpc :7545/:7645/:7845, raft :50050/50051/50053 | HA sequencer cluster |
| rollup-boost A/B/C | engine :9751/:9752/:9753, fb WS :1112/:1115/:1116 | builder proxy |
| op-rbuilder A/B/C | http :2222/:2223/:2224, engine :9551/:9552/:9553 | external builders |
| preconf gateway | http+ws :8547 | leader-aware preconfirmations |
| CGT chain 420902 | EL :8845, node :9847 | OMNI gas chain (self-sequenced, no conductor) |

## Tooling

- **Single source of truth**: `.deployer/anvil/scripts/topology.psd1` holds
  every port, peer ID and pairing. `start-stack.ps1`, `restart-*.ps1` and
  `start-node-c.ps1` all render their arguments from it via
  `lib-topology.ps1` — change the topology in the psd1, never inline in a
  launcher.
- **One-shot verification**: `verify-stack.ps1` runs forge tests, go
  vet/build for `.devnet-tools`, then live checks (all node syncStatus,
  unsafe-head spread, exactly-one-raft-leader, derivation progress, CGT app
  contracts deployed). Exit 0 = healthy.
- **App-layer addresses**: `.deployer/anvil/app-addresses.json` is the
  canonical registry (written by `cgt_redeploy_v2.py`).
  `update_taksi_env.py` renders `taksi.env.example` from it — never edit
  env addresses by hand.
- **Deployer nonce discipline**: the canonical bridge addresses assume the
  deployer starts at nonce 0 on BOTH chains. Never send test/funding txs
  from the deployer key before the app-layer deploy — a burned nonce 0
  makes the L1 bridge's predicted L2 pair unreachable (this happened once;
  the recovery was redeploying L1 bridge bound to the actual address).

## Failure modes and fixes (all observed live)

### 1. Conductor split-brain / leadership flap
Symptoms: two conductors report `leader=true`, or leadership flaps with
`failed to start sequencer: no unsafe head` / `block hash does not match`.
Fix: restart all three conductors together (`.deployer/anvil/scripts/restart-conductors.ps1`).
If raft FSM is corrupted (MarshalSSZ panic in snapshot.Persist): stop all
conductors, delete `raft1/ raft2/ raft3/`, restart, re-add voters:
```
conductor_addServerAsVoter("cond2","127.0.0.1:50051",0)
conductor_addServerAsVoter("cond3","127.0.0.1:50053",0)
```

### 2. Sequencer stuck at "no unsafe head" after raft wipe
Fresh raft has an empty unsafe-head tracker; the leader refuses to start
sequencing and transfers forever. Fix: commit the leader node's current unsafe
head via `conductor_commitUnsafePayload` using `.devnet-tools/sync_commit.py`
(leader-aware; envelope MUST include `parentBeaconBlockRoot` or raft crashes
at the next snapshot — real panic in `ExecutionPayloadEnvelope.MarshalSSZ`).

### 3. Unsafe-head divergence between ELs / op-nodes
Symptoms: `unsafe head mismatch`, `consensus_num > node_num`.
Cheapest recovery: unwind ALL ELs to the deepest common safe ancestor instead
of replaying thousands of divergent payloads:
```
op-reth stage unwind --datadir /var/lib/omnicor-el/l2-<x> \
  --chain .deployer/anvil/genesis.json to-block <N>
```
then wipe raft dirs, restart nodes (FindL2Heads returns instantly when
unsafe==safe), restart conductors, commit head per §2. Unsafe-only history
is protocol-legal to drop; nothing safe/finalized is lost.

### 3a. Deep divergent reorg: datadir transplant beats unwind
Observed 2026-10-05. When a lagging EL must reorg >10k blocks, the
in-engine unwind recomputes state per-block ("Changeset cache MISS …
aggregate DB-based computation" — observed 0.2-8 blk/s; FCU retries
starve it further, effectively a livelock). Cheapest deterministic fix
when a healthy peer EL exists:
1. Stop the DONOR EL briefly (cold copy is mandatory — a `cp -a` of a
   LIVE datadir produced an unsorted IntegerList → `Fatal error in
   consensus engine` panic at startup)
2. `mv l2-X l2-X-old; cp -a l2-donor l2-X` (dirs are ~300-500 MB here —
   seconds)
3. Delete copied locks: `rm l2-X/db/mdbx.lck l2-X/static_files/lock`
   (they embed the donor PID and the node refuses to boot otherwise;
   the first `static_files/lock` under `db/` is NOT the one that
   blocks — both live under their respective subdirs)
4. Restart donor + transplanted EL; reth runs "Three-way healing" on
   the static files, then serves normally. op-node reconciles safedb
   itself (mismatched-hashes → reset → rederive).
Datadirs carry NO node identity — p2p key/JWT/ports all come from CLI
args, so a donor copy is a drop-in for any same-genesis node.

### 4. op-node init "Walking back L1Block" for a very long time
FindL2Heads traverses unsafe→safe on every start; with a large
unsafe−safe gap this takes ~0.3-1.5 blk/s (hours at 10k+ blocks).
**Devnet launchers now pass `--l2.skip-sync-start-check`**: once the unsafe
head's L1 origin is confirmed canonical, the walk jumps straight to the
safe head — the whole FindL2Heads finishes in ~1 s. The flag only defers
L1-origin verification of unsafe blocks, which is fine on anvil (never
reorgs); do not copy it to a real-L1 deployment without evaluating reorg
risk. Fallback options if it is ever off: unwind the EL so unsafe≈safe
first (see §3), or copy a healthy peer's `safedb` directory while both
nodes are stopped.

### 5. rollup-boost EOF / ServiceUnavailable gating engine calls
Boost marks itself unhealthy when the EL's unsafe timestamp is stale and can
EOF op-node's init queries → deadlock (node can't init because boost won't
serve because head is stale). Fix: point the node's `--l2` directly at the EL
authrpc port until the head is fresh, then repoint to boost.
Also: `rollup-boost v0.7.17` `--ignore-unhealthy-builders` semantics are
inverted vs docs — with the flag set, FCU to an unhealthy builder is SKIPPED
(deadlock). Run without it.
If the whole boost/builder pipeline is down (e.g. Docker Desktop stopped —
boost, rbuilders and the fb relays all live in containers): start the stack
with `-NoBoost` (`devnet-ctl.ps1 start` auto-detects a dead WSL boost
endpoint and selects the mode itself; the Windows tcprelay keeps accepting
9751 even with a dead backend, so never probe the relay port). Nodes then
use raw EL authrpc, conductors skip the flashblocks ws feed, Raft HA keeps
working; only fb fan-out is lost.

### 6. WSL memory livelock (WSAENOBUFS, VM unresponsive)
4× op-reth + docker on a 7.7 GB host. Mitigations now in place:
`.wslconfig` memory=5GB swap=8GB; txpool caps reduced
(pending 50k/64MB, basefee 20k, queued 50k, account-slots 16384).
Never run the spam tool while the cluster is recovering.

### 7. Batcher stalled → safe head frozen
Batcher queries `--rollup-rpc` of ONE node; if that node is initializing,
batching stops silently (`empty BlockRef in sync status`). Fix: restart the
batcher pointing at a healthy node (`--rollup-rpc=http://127.0.0.1:9647`).
Backlog then drains automatically via derivation.

### 8. Long replay after downtime (deposit-only catch-up)
If the sequencer was stopped for hours, derivation replays one L2 block per
second of downtime (~1-2 blk/s). The sequencer defers
("Detected new block-building from L1 derivation, avoiding sequencing")
until the backlog is exhausted, then produces fresh-timestamped blocks and
the conductor health check recovers automatically. No intervention needed —
it is slow but correct.
Faster variant: the catch-up sequencer and the derivation pipeline race —
each derived frame reorgs back sequencer progress (out-of-order unsafe
inserts, e.g. number=46656 after 46748). Stopping the batcher removes the
new-frame source; frames already posted on L1 still drain, but the
sequencer stops losing reorg races sooner. Restart the batcher once the
unsafe timestamp is current again (it aborts on boot while no sequencer is
active — start it after the leader holds, not before).

### 9. L1 history corrupted (e.g. evm_increaseTime warp)
If L1 timestamps jump ahead of L2 (`evm_increaseTime`), the sequencer enters
NoTxPool and derivation stalls — upstream `maxSequencerDrift` (1800s fjord)
correctly refuses blocks whose L1 origin is in the future. Do NOT patch the
drift constant to recover; wipe and redeploy instead:
```
devnet-ctl.ps1 stop                      # everything down
start-stack.ps1 -Phase anvil            # fresh L1 (new genesis hash)
redeploy-l1.sh                          # superchain + OPCM + both chains
python .devnet-tools/l1_deploy_omni.py  # OMNI token/vesting/bridge
# wipe: EL datadirs (WSL /var/lib/omnicor-el), safedbA/B/T, raft1/2/3,
#       p2p dirs, builder containers' datadirs (docker rm -f + bind wipe)
run-l2-el.sh + run-cgt-el.sh            # fresh ELs on new genesis
docker compose up builders/boosts       # after datadir wipe
# $Phase takes ONE value — run each phase in sequence:
start-stack.ps1 -Phase nodes
start-stack.ps1 -Phase conductors
start-stack.ps1 -Phase batcher
start-stack.ps1 -Phase proposer
```
Then bootstrap raft unsafe head per §2 (commit the head payload), re-add
voters, and regenerate `rust/kona/.../custom-configs/omnicor/configs.json`
from the new `rollup*.json` + `state.json` BEFORE rebuilding the kona
prestate — the FPVM prestate embeds genesis hashes, so a stale prestate
makes every type-8 game unprovable.

### 12. Cold-start after a long outage: full recovery sequence
Observed 2026-10-04 (~32h stall). Symptoms stack in order: op-node init
fails (dead boost relays RST the engine call) → raft elects-then-flaps
(`server (follower) is not healthy`) → `unsafe head mismatch` →
`conductor_active=false`. Ordered fix:
1. WSL ELs first, as root (datadir lock is root-owned):
   `wsl -d Ubuntu -u root -e run-l2-el.sh a 8645 8651 8646 30304` (+ b/c,
   CGT via start-cgt-stack.ps1 -Phase el)
2. Nodes via `restart-node-*.ps1` (BypassBoost) or `start-stack.ps1 -Phase nodes -NoBoost`
3. If heads diverged, post the highest tip to laggards:
   `admin_postUnsafePayload` on B/T with A's tip envelope (see
   `.devnet-tools/sync_commit.py` `envelope()`)
4. If raft FSM claims a head no EL has (`consensus_num > node_num`,
   committed blocks lost with the dead builders): stop conductors,
   delete `raft1/2/3`, restart conductors with `-UnsafeInterval 200000`
   (heads are ancient → every server fails the 60s age check → flap
   forever; a wide interval breaks the deadlock)
5. `sync_commit.py` until the leader holds and calls startSequencer
6. **Check `conductor_active` — a paused conductor resumes nothing**;
   `conductor_resume` on all three
7. Once the unsafe timestamp is fresh again, restart conductors at the
   default interval (60) and, if running `-NoBoost`, restart nodes via
   `-Phase nodes` without it once boost is back
8. Start batcher/proposer (batcher aborts at boot if no sequencer is
   active yet — that is expected, restart it after step 6)

### 13. Engine dead-lock: proposer superroot queries stall every FCU
Observed 2026-10-05. With `--superroot-rpcs=` the proposer calls
`superroot_atTimestamp` on every op-node ~every 10 s. While the chain is
behind wall clock, the requested timestamp maps to a *future* L2 block;
each call resolves to `OutputV0AtBlock` on the EL, and reth answers it by
serially re-computing changesets one block at a time on the **engine
thread** ("Changeset cache MISS in range, falling back to aggregate
DB-based computation" — ~1.2 blk/s, ~11.6k blocks observed). Client-side
timeouts do NOT cancel the EL-side work — the backlog queues on the
engine thread and every `engine_forkchoiceUpdated` then exceeds the
(default 10 s, now `--l2.engine-rpc-timeout=60s`) deadline. op-node
treats that as a temporary engine error → derivation step backoff grows
exponentially → unsafeHead never reaches the sequencer →
`admin_startSequencer` returns `no prestate` forever.
Fix: kill the proposers (and anything else polling superroot/output
roots) **before** starting node recovery; wait until the EL's engine
thread drains (miss counter stops growing), only then restart proposers.
Do not restart a proposer while safe << unsafe.
If the poller is already gone but the EL still grinds (miss counter still
descending — the queued work is in-memory, not on disk), **restart that EL
process**: the backlog dies with it and the engine thread unblocks
immediately. Verify post-restart that no new `Changeset cache MISS` lines
appear; if they do, the recompute is being re-driven by an op-node op
(deep unwind, see §14) and is real work, not a stale queue.

### 14. op-node init spins on "Found highest L2 block with canonical L1 origin"
Observed 2026-10-05. Symptom: after a long outage the node logs that line
repeatedly at init and never proceeds; safe head stays frozen while
unsafe advances. Cause: the `SkipSyncStartCheck` fast-path jumped the
walk-back to the previous safe head even when the highest L2 block with
a canonical L1 origin was AT or BELOW the safe head — the jump
re-assigned the traversal cursor to itself → infinite loop.
Fixed in-tree (`op-node/rollup/sync/start.go`): the jump now only fires
while the cursor is still above the safe head; regression cases live in
`start_test.go` ("skip check, canonical origin at/below safe head" —
both hang on the old code). Rebuild `bin/op-node.exe` when in doubt.

### 15. Conductor leader active but sequencer never starts
Leader elected, `conductor_active=true`, `conductor_paused=false`, yet
`admin_sequencerActive=false` and no new unsafe blocks — and the
conductor's log file is stale (process restarted under a different log
target, e.g. during the raft wipe/re-add cycle). The raft-commit path
that normally calls startSequencer never fired. Fix: start it manually —
post `admin_startSequencer` with the node's current unsafe head hash;
the conductor resumes normal health-check management from there.
Verify with `admin_sequencerActive` and rising `eth_blockNumber`.

### 16. Derivation reorgs mempool-tx blocks over empty submitted batches
Symptom: `L2 reorg: existing unsafe block does not match derived
attributes` `err="transaction count does not match. expected: 1. got: N"`,
unsafe head oscillating ~100-150 blocks while safe ratchets up slowly.
Cause: the batcher earlier submitted EMPTY span batches covering heights
the sequencer later rebuilt WITH mempool transactions (e.g. spam left in
the pool). L1 batch data wins — those unsafe blocks are protocol-invalid
and get reorged to the empty version. Self-heals: each cycle drops the
tx-blocks, replaces them with empty ones, safe advances. Speed it up by
draining the txpool so the sequencer stops producing tx-blocks in the
contested range. Harmless but noisy; expect it after any recovery where
spam ran while empty batches were in flight.

### 17. Anvil head-churn = benign "possible L1 re-org" warns
With anvil automine (~6 s) and the node's L1 poll interval (~12 s), every
new head has a different parent than the last seen head → op-node logs
"L1 head signal indicates a possible L1 re-org" every cycle. Harmless on
anvil; on a real L1 it would indicate genuine reorgs.

### 18. restart-conductors.ps1 starts boost mode — conductors exit if boost is down
`restart-conductors.ps1` previously hardcoded the rollup-boost
flashblocks wiring; when the boost pipeline is down (Docker dead, no ws
on :1112/1115/1116) every restarted conductor initializes raft, fails the
ws dial after ~30 s, and exits — `conductor_*` RPCs all return
connection-refused. The script now accepts `-NoBoost` and
`-UnsafeInterval` (same semantics as `start-stack.ps1`); use
`start-stack.ps1 -Phase conductors -NoBoost -UnsafeInterval 60` as the
canonical recovery invocation. After restarting conductors, verify
`--healthcheck.unsafe-interval=60` is back on the cmdline (recovery runs
used a very wide interval to break the stale-head flap deadlock —
leaving it wide disables the stale-head watchdog).

### 19. CGT has its own batcher — start it separately
Only the main-chain batcher is covered by `start-stack.ps1 -Phase
batcher`. CGT (420902) safe head stalls without its own:
`start-cgt-stack.ps1 -Phase batcher -NoBoost`. It uses a dedicated key
(`$TOPO.Cgt.BatcherKey`) so the two txmgr pairs never race on L1. On
restart it walks the unsafe backlog into local state before posting —
expect ~seconds per thousand blocks and "publishSignal channel is full"
warnings; that is normal, not a stall.

### 20. Per-block tx ceiling is the Jovian DA-footprint cap, not compute
Observed 2026-10-05: with a saturated pool, every block carried exactly
1500 pool txs + 1 deposit. Cause: Jovian's DA-footprint accounting —
`cumulative_da_bytes * daFootprintGasScalar > block_gas_limit` stops tx
inclusion (`is_tx_over_limits` in `rust/op-reth/crates/payload/src/builder.rs`).
`daFootprintGasScalar` defaults to **400** (`DAFootprintGasScalarDefault`
in op-node) when the rollup config carries 0 — so the DA byte budget is
`block_gas_limit / 400` (150 KB at 60M ≈ 1500 minimal-transfer txs).
Raising the L2 gas limit scales the budget proportionally. Live upgrade
path (rehearsed on devnet):
1. `cast send <SystemConfigProxy> "setGasLimit(uint64)" <new>` from the
   SystemConfig owner — propagates to all nodes via ConfigUpdate
   derivation within ~1 min. Function is `setGasLimit`, NOT
   `updateGasLimit` (that name reverts empty). Ceiling: 500M.
2. Every EL that may sequence needs `--builder.gaslimit` >= the new
   value (it is `min(evm_limit, builder_flag)`) — bump the flag in
   `.devnet-tools/run-l2-el.sh` / `start-el.sh` and restart the ELs.
Measured: 60M → 1501 tx/block flat cap; 120M → saturated cap at
**3001 tx/block (~63 Mgas) sustained** on 8 WSL cores — the DA budget
scales linearly with gas limit (150KB→300KB). On fewer cores the cap is
still reachable but the fill becomes pool-vs-builder race-limited.
Do NOT lower `daFootprintGasScalar` for throughput — it is the honest
L1-DA price; on real L1 that would under-charge blob costs.

2026-10-05 follow-up, same procedure to **200M** (`setGasLimit(200M)` +
`--builder.gaslimit 200M`): peak block **5001 tx / 105.05 Mgas** — the
500KB DA cap — while a concurrent block sampler showed sustained fat
blocks throughout the blast. **400M** was also tested: peak dropped to
3973 tx / 83 Mgas — the Jovian DA budget (~1MB) no longer binds; the
EL payload-builder saturates at ≈80–105 Mgas/s on 8 shared WSL cores,
so gas limit above ~200M buys nothing on this hardware and only invites
over-commit/missed slots. Settled on **200M** as the production devnet
value; on dedicated hardware the same linear DA-cap lever scales
further (raise limit, re-measure, the cap is deterministic).
Submission during the 200M blast measured ~1100 tx/s end-to-end over
the tcprelay bridge.

### 21. tcprelay IS the Windows↔WSL bridge — never bulk-kill it
All Windows-localhost EL/RPC ports are tcprelay.exe processes forwarding
to the WSL VM IP (`start-all-relays.ps1` recreates them; it resolves the
current `hostname -I` and skips ports already bound). WSL
`localhostForwarding` does NOT expose these ports by itself in this
setup. Killing every tcprelay at once silently severs EL RPC,
auth-rpc, node RPC and builder endpoints for every Windows-side service
— op-node, batcher, proposer, preconf all lose connectivity while the
WSL daemons keep running. The relays are disposable only in the sense
that the script can recreate them; they are NOT optional.
Incident 2026-10-05: stale relays to a dead boost backend added ~2 s to
the preconf send path; the correct fix is gateway-side parallel ingress
(preconf now races every endpoint, first ack wins), not deleting the
bridge.

### 22. Preconf gateway — parallel ingress (accepted ~17 ms median)
`preconf/main.go SendRawTransaction` races the tx to ALL ingress
endpoints (leader builder, leader EL, follower ELs) concurrently and
returns the first successful ack — previously the leader's builder
endpoint was tried first sequentially, so a 2 s relay stall became the
accepted latency. `"already known"` counts as success (racing duplicates
are expected). Two-step fix: parallel ingress (~220 ms), then
first-ack-return — respond as soon as ANY endpoint acks instead of
waiting for every endpoint. Measured end state: **accepted 8-85 ms,
median ~17 ms; confirmed 1.5-2.0 s** (one block interval + phase).

### 23. op-challenger runs in WSL natively — keep the binary fresh
`start-challenger.sh 420901` (root, `nohup … > /tmp/challenger.log`).
Reaches Windows services via the inbound tcprelay set (§21). With a
fresh DGF the "array out-of-bounds (0x32)" error is benign — it means
zero games exist yet; it clears once the proposer posts the first game.
Challenger is a Windows-*invisible* process — `Get-Process` on the host
will not show it; check `pgrep -f op-challenger` inside WSL.

**Binary must track the checked-out source.** On 2026-10-05 the deployed
`bin/op-challenger` was 38 commits behind the tree and missed upstream
fixes for super/permissioned games (`#21811` anchor advancement,
`#21739` selected-VM state conversion, `#21681` no absolute-prestate
load for permissioned games). A stale binary mis-evaluates type-8
games. Rebuild:
```
wsl -d Ubuntu -u root -- bash -c \
  'cd /mnt/d/OMNICOR/op-challenger && go build -o /mnt/d/OMNICOR/bin/op-challenger ./cmd'
```
(the build runs as the user that owns `bin/`; killing the old process
also needs root — `wsl -u root -- kill <pid>`). Restart with the same
flag set; log to `.deployer/anvil/logs/challenger.log`, metrics `:7360`.

Verification: `op_challenger_up 1`, `op_challenger_tracked_games`
reflects the live set, zero `panic`/prestate-validation spam in the log.
`bin/op-challenger game-proposal-outputs --l1-eth-rpc … --rollup-rpc …
--game-factory-address …` prints `rootMatch`/`safeHeadAtOrAboveBlock`
per game — the ground-truth check before trusting challenger actions.
Claims on a game are read via `claimData(uint256)` — the claimant field
identifies who posted (our challenger is `0x976ea74026e726554db657fa54763abd0c3a0aa9`).

### 24. Conductor failover drill — measured +3.2 s to block resume
Procedure: under load, `taskkill /F /IM` the leader's op-conductor (or
kill by PID). Measured 2026-10-05 (cond1 killed, cond3 took over):
**leader election +2.7 s, next L2 block +3.2 s** — ~3 missed 1 s slots
total, zero unsafe divergence, no manual intervention.
Rejoining the killed voter is NOT `start-stack -Phase conductors` (that
restarts all three and triggers a second failover). Use
`.devnet-tools/rejoin-cond1.ps1`-style single-voter start rendered by
`Get-ConductorArgs`, with `Bootstrap=$false` — a rejoining voter that
still carries `--raft.bootstrap` risks forming its own cluster
(split-brain). The bootstrap flag is only for initial cluster formation.
Post-drill checks: exactly one `conductor_leader=true`,
`conductor_clusterMembership` = 3 voters, `admin_sequencerActive` true
only on the leader's node, unsafe heads converging (lag < 5 s).

### 25. Txpool: gossip parks txs in `queued` — ingress must reach the leader EL
Observed live after a leader change: a non-origin EL receives gossiped
tx bodies but they land in `queued` behind nonce gaps that never fill
(the origin node never re-announces). Symptom: leader EL shows
`txpool_status` pending=0 / queued=35k+ while producing 1-tx blocks.
Even `--tx-propagation-mode all` only delivers bodies — promotion still
needs contiguous nonces.
Consequences and mitigations now in `run-l2-el.sh`:
- `--tx-propagation-mode all` — every EL gets full tx bodies (free in a
  3-EL cluster; reduces the gap surface).
- `--txpool.lifetime 600` — stale queued txs evict after 10 min
  (default 3 h meant permanently stuck pools on this devnet).
- `--txpool.pending/queued-max-count 100000` — a 75k-tx burst at
  ~2.5k tx/s ingress overflowed the old 50k pending cap and silently
  evicted ~68k txs. Pending caps must exceed burst × drain time.
- **Architectural rule**: ingress must fan out to (or race) the current
  leader's EL — the preconf gateway already does this, which is also why
  its `accepted` signal tracks real includability. Submission direct to
  the leader EL reproduces the full 5,001-tx/105-Mgas block on any
  voter; submission to a follower relies on this same gateway behavior
  in production.

### 26. ELs run under systemd (omnicor-el@.service)
`D:\OMNICOR\.devnet-tools\omnicor-el@.service` — Type=simple template
unit wrapping `run-l2-el.sh` (which now defaults ports per node name:
a=8645, b=8745, c=8945). `Restart=on-failure`, `OOMScoreAdjust=-500`,
logs via `journalctl -u omnicor-el@a`. Install:
`cp .devnet-tools/omnicor-el@.service /etc/systemd/system/ &&
systemctl daemon-reload`. This is also the Selectel service template —
on the VPS the same units run with `ExecStart` pointing at the local
repo path (edit `User=`/`ExecStart=` accordingly).
Measured live: killing the leader EL under systemd — EL back and
responding in ~8 s, cond3 kept leadership, blocks resumed with zero
manual steps. A follower EL restart is invisible to the chain.

### 27. anvil time travel — blast radius and recovery (2026-10-05)
`anvil_increaseTime` (+~24 h, used to expire dispute clocks fast) leaves the
L1 clock permanently ahead of L2 wall-clock time. On this devnet it caused
three cascading failures, in order of appearance:

1. **op-proposer stalls silently.** `FetchDGFOutput` compares each game's
   `createdAt` (an L1 block timestamp) against a **wall-clock** cutoff
   (`now - proposalInterval`). A game created post-jump has `createdAt`
   ~24 h in the future → counts as "recently proposed" until wall clock
   catches up → zero proposals, no error logs. Fix shipped in
   `op-proposer/proposer/driver.go`: the cutoff now uses
   `max(localClock, l1HeadTimestamp)` — cadence is measured in L1 chain
   time, which is what game timestamps actually are. Covered by
   `TestL2OutputSubmitter_FetchDGFOutputCutoffUsesClock/L1ClockAheadUsesChainTime`.
   Restart proposers after rebuilding `bin\op-proposer.exe`.
2. **Sequencing-window expiry → infinite tail-reorg loop.** The L2
   sequencer can only pick L1 origins with `origin.ts <= l2.ts`, so after
   the jump the origin pins to the last pre-jump L1 block while head-L1
   races ahead. Once `headL1 - l1origin` exceeds `seq_window_size`
   (default 3600), every batch lands expired → derivation produces
   deposit-only blocks → `"expected: 1. got: N"` reorgs every few seconds
   → user txs (incl. withdrawals) are reorged out of every retry.
   Devnet fix: raise `seq_window_size` in `rollup*.json` (we use 200000,
   ~4.6 days of L1 blocks) and restart the chain's op-nodes + batcher.
   Note the batcher restart alone does NOT help — stale batches already
   on L1 keep forcing reorgs; the node must be restarted with the larger
   window. For production do NOT enlarge the window blindly — the real
   fix is never to jump L1 time on a live chain.
3. **CGT proposer BadAuth (0xd386ef3e).** `SuperPermissionedDisputeGame.initialize`
   requires `tx.origin == proposer()` baked into the impl's clone args.
   After a DGF redeploy the impl's proposer was anvil#5 while topology
   still pointed CGT at anvil#9 → every `create()` reverted at
   gas-estimation. Read `proposer()` off a live game of that type
   (`gameAtIndex` → `proposer()` on the clone — it reverts on the bare
   impl because the arg lives in appended clone data) and set
   `Cgt.ProposerKey` accordingly.

Also note: the jump pins `l1origin` permanently (~block 48687 here).
Sequencing still works (the drift check does not stall this build), but
`headL1 - l1origin` grows forever — monitor it, and prefer fresh devnet
state over time travel for anything but clock-expiry drills.

### 28. Rolling restart of raft-managed op-nodes
To reload `rollup.json` (or binaries) without losing sequencing:
1. `admin_sequencerActive` on each node RPC → find the leader.
2. Followers first: capture `Win32_Process.CommandLine`, `Stop-Process`,
   re-`Start-Process` with identical args (conductor re-adopts them).
3. Leader last: `conductor_transferLeaderToServer("<id>","<addr>")` on the
   leader's conductor RPC (7545/7645/7845), verify
   `conductor_leader=true` moved, then restart the old leader.
Failover measured again during the 2026-10-05 window bump — cond1 took
over, no gap in block production.

### 29. localhost resolves to ::1 → ~2 s per L1 call → derivation starves
Observed 2026-10-05, root cause of a full-cluster safe freeze (main safe
stuck 274515, CGT safe stuck 266069 for ~1 h). anvil binds `127.0.0.1`
only. On Windows `localhost` resolves to `::1` first; the v6 connection
to an unbound port does not refuse instantly — it stalls ~2.05 s before
happy-eyeballs falls back to v4. EVERY `http://localhost:9545` call paid
~2 s (measured: `net_version` 2046 ms, `eth_blockNumber` 2047 ms; the
same call to `127.0.0.1` was 15-69 ms). Symptoms cascade: op-node L1
traversal walks ~0.5 blk/s instead of ~100 blk/s → `failed to find L1
block info … context deadline exceeded` → safe frozen on BOTH chains
while unsafe advances; anvil looks "overloaded" but idles (CPU ~0.03/s,
zero disk I/O — it is just waiting on clients, not thrashing).
Two diagnostic shortcuts that saved hours:
- `urllib`/`http.client` to `127.0.0.1` vs `localhost` — a 100× split is
  the signature. Do not trust a `localhost` latency measurement alone.
- `--block-time` changes do NOT move the 2.05 s — it is a per-connect
  stall, not mining-lock duty.
Fix (now in `start-stack.ps1 -Phase anvil`): keep anvil on v4 and run a
permanent `tcprelay.exe -listen [::1]:9545 -to 127.0.0.1:9545` so the
::1 dial succeeds instantly. Alternative considered: `--host ::` — on
Windows that binds IPv6-ONLY and breaks every `127.0.0.1` consumer
(incl. the WSL inbound tcprelay set) — do not use it.
Post-recovery protocol when L1 has been rewound (e.g. anvil restarted
from a `--state` dump — it rewinds to the last dump, ~hundreds of
blocks): restart op-nodes (they otherwise idle-wait at
`can't find next L1 block info` for a height that will never exist with
the same hash), THEN restart batchers (a batcher that booted off a stale
node view sticks on `sequencer currentL1 reversed` forever — its
`prevCurrentL1` baseline never resets). After the relay fix, traversal
re-walked ~3.5k L1 blocks in ~30 s and main safe caught up 274899→278675
in ~6 min.

### 30. anvil_impersonateAccount txs poison derivation: txHash ≠ keccak(RLP)
Observed 2026-10-05, second root cause of the same safe freeze.
`anvil_impersonateAccount` + `eth_sendTransaction` mines a tx with a
SYNTHETIC signature `r=0x1, s=0x1, yParity=0`. Anvil indexes the tx and
writes receipts/logs under the hash of the UNSIGNED payload, but the
block's transaction list re-serializes with the fake signature — so
`keccak(RLP)` ≠ the txHash in receipts. The block is internally
inconsistent BY ANVIL'S OWN DATA.
op-node's `op-service/sources/receipts.go` `validateReceipts` catches it
at `log.TxHash != txHashes[i]` — the check is correct, DO NOT weaken it.
Every consumer that decodes the block and recomputes tx hashes (all
op-nodes) loops forever on
`failed to fetch receipts of L1 block … for L1 sysCfg update:
log 0 of tx … has unexpected tx hash …` — a permanent dead stop, not a
temporary error: the mismatch is in the stored block itself.
Confirmed by MITM capture + hash reconstruction: wire data looked
consistent (`eth_getBlockByNumber` hash-list + `eth_getBlockReceipts`
agree), but `eth_getBlockByHash(hash, true)` — what `blockCall` uses —
re-serializes to a different tx hash. Reproduce the expected hash in Go:
`types.NewTx(&types.DynamicFeeTx{…, V:0, R:1, S:1}).Hash()`.
Recovery — the poisoned block must leave history, there is no way to
patch a receipt:
1. `anvil_reorg` does NOT work on `--state`-loaded chains (no in-memory
   rewind snapshots; returns null, head unchanged).
2. Stop anvil, replace `--state` file with a dump predating the tx,
   restart anvil (rewind to the dump tip). Keep a copy of the poisoned
   file for forensics.
3. Re-apply the intended change with a REAL signed tx from the owner's
   dev account — impersonation was unnecessary here; the SystemConfig
   owner 0x3c44cddd… is anvil#2 (`cast send --private-key <anvil#2>`).
4. Nodes re-walk and pass the sysCfg update; batchers need a restart
   (stale `prevCurrentL1`); nodes whose traversal sits ABOVE the new
   head idle until L1 outgrows their position, then reset normally.
Rule going forward: NEVER use `anvil_impersonateAccount` /
`anvil_setStorageAt` for role or config changes on this devnet — every
role owner is a dev account with a known key; sign real transactions.
Impersonated/config-hack txs create blocks no honest client can
re-validate.

### 31. Fallout of the +24 h L1 time warp (three latent stalls)
Observed 2026-10-05 after the L1 clock was restored to wall time. The
`evm_increaseTime` from §27 keeps biting through state it left behind —
all three are now fixed in code or procedure:

a) **Proposer cadence freeze on future-dated games.** Games created
while L1 ran +24 h ahead carry `timestamp > now`. `HasProposedSince`
scans backwards and returns the newest matching game as "recently
proposed" — a future timestamp can never age past `proposal-interval`,
so the submitter went permanently silent (debug log only:
`Duration since last game not past proposal interval duration=-21h…m`).
Fixed in `op-proposer/proposer/driver.go`: a game timestamped more than
1 min in the future is ignored for cadence purposes. Both proposers
redeployed; game creation resumed within one poll cycle.

b) **Sequencer empty-block lock (`NoTxPool`).** L2 time advanced ~24 h
past the wedged L1 origin (origin stuck at 48687, the last pre-warp
block). Post-Fjord `maxSequencerDrift` is a hardcoded 1800 s constant —
`rollup.json`'s `max_sequencer_drift` was ignored. Patched
`op-node/rollup/chain_spec.go`: a config value ABOVE the Fjord constant
now wins (never lowers it); both rollup.jsons set 200000. User txs
mine immediately again. Review before upstreaming — this is a devnet
recovery affordance, not production protocol.

c) **Zombie mempool on a follower EL.** 37 k spam txs sat "pending" on
l2-a while the sequencer built on l2-b. Fresh txs gossip fine (proved
by direct inclusion), but l2-b's seen-cache already held the old hashes
from before its restart — re-announces are dropped, so the backlog never
re-propagates. A leftover `spam.exe` kept re-injecting them into l2-a.
Fix: kill the spammer; pool drains via `--txpool.lifetime 600`. Send
load tests to the ACTIVE sequencer's EL, or expect gossip-only
visibility elsewhere.

### 33. Portal delays shipped with production values — proxy upgrade fix
Observed 2026-10-05 while finalizing the withdrawal E2E. Both
OptimismPortal proxies read `proofMaturityDelaySeconds=604800` (7 days)
and `disputeGameFinalityDelaySeconds=302400` — although intent.toml's
`deployOverrides` specify 120/60. The L1 deploy simply never applied the
overrides; `finalizeWithdrawalTransaction` reverts
`OptimismPortal_ProofNotOldEnough` forever within devnet lifetime.
Root fix (preserves all storage — proven withdrawals, anchors):
1. Deploy `OptimismPortal2(120)` and `AnchorStateRegistry(60)` impls —
   `packages/contracts-bedrock/scripts/deploy/DevnetDelayFix.s.sol`,
   `forge script … --rpc-url http://127.0.0.1:9545 --broadcast`.
   NOTE: `forge create`/`forge script` silently simulates unless
   `--rpc-url` is passed as a flag (env var ignored by this version).
2. `ProxyAdmin.upgrade(proxy, impl)` from the chain's proxyAdmin owner
   (0x70997970…, a dev account) for each of the four proxies:
   main 0xd96Fb74…→{portal 0x61a1371d…, ASR 0x82C820E4…},
   CGT 0x90e072Ac…→{portal 0x09eEBF34…, ASR 0x32Aa5980…}.
   `proxyType[]` is already `ERC1967` — `upgrade` routes to
   `IProxy.upgradeTo`. Simulating first (`cast call --from owner`)
   returns `0x` on success.
3. Re-check `proofMaturityDelaySeconds()` on both portals: 120.
Verified: proven withdrawal finalized ~3 min after resolve.
AUDIT NOTE (unresolved): the L1-side release did not credit the
recipient's OMNI ERC20 balance — the bridge holds 0 OMNI (genesis L2
supply is unbacked on L1). Protocol path proven; withdrawal-solvency
accounting for the CGT gas-token model needs design review.

### 34. op-reth txpool survives restarts via txpool-transactions-backup.rlp
Local (RPC-submitted) txs are flushed to
`<datadir>/txpool-transactions-backup.rlp` on shutdown and re-loaded on
boot — a restart does NOT drain a zombie pool. Delete the file first,
then start the node. `--txpool.lifetime` does not evict `local` entries.

### 32. Build outputs land in TWO places — verify the running binary
`make`-style builds put services in `D:\OMNICOR\bin\`, but ad-hoc
`go build -o <pkg>/bin/…` lands elsewhere. The proposer fix above was
"deployed" twice to `op-proposer\bin\` while the live processes ran
`D:\OMNICOR\bin\op-proposer.exe` — symptoms unchanged, an hour lost.
Before/after every redeploy:
`Get-Process <svc> | Select Path` and confirm the path you just built,
and grep the binary for a marker string from your patch.

## Verification checklist (post-recovery)

- `optimism_syncStatus` on 9647/9747/10047: identical unsafe/safe/finalized
- exactly one `conductor_leader=true` across 7545/7645/7845
- `conductor_clusterMembership` shows all 3 voters
- EL latest block timestamp age < 5 s (sequencing live)
- `curl ws probe` on the leader's fb port (8400/8401/8402)
- preconf e2e: accepted ~17 ms median (8-85 ms), confirmed ~1.5-2 s
  (NoBoost gateway, §22); flashblock events only when a boost pipeline
  is attached
- **tx inclusion**: `go run .devnet-tools/spam/main.go -senders 10
  -txs 50 -concurrency 50 -batch 25` — on a healthy 1s-block chain a
  500-tx burst drains in ~4 s into a single ~500-tx block (~10.5 Mgas);
  2026-10-05 measured 1329 tx/s submission end-to-end. With a deep pool
  at 200M gas limit, peak blocks reach **5001 tx / ~105 Mgas**
  (DA-footprint budget 500 KB/block, see §20)
- both batchers running: main (l2=8645) **and** CGT
  (`Get-Process op-batcher` → 2 processes)

### 10. Challenger rejects every game: "output root absolute prestate does not match / Contract: 0xdead…"
The ASR was initialized with the `0xdead…` sentinel anchor (deploy path that
skips `ComputeGenesisOutputRoots` or an intentionally seeded placeholder).
`initialize()` is a `reinitializer` — it cannot be called again. For devnet,
write the anchor directly into the proxy storage:

Layout (verified against live storage):
- slot 0: initialized|systemConfig, slot 1: disputeGameFactory, slot 2: anchorGame, slot 3: startingAnchorRoot.root, slot 4: startingAnchorRoot.l2SequenceNumber

```
# 1) real output root at a safe/finalized L2 block (e.g. 0x1444)
optimism_outputAtBlock -> root, l2BlockNumber
# 2) anvil_setStorageAt on the ASR proxy:
slot3 = outputRoot
slot4 = uint256(l2BlockNumber)
# verify: ASR.getAnchorRoot() == (outputRoot, l2BlockNumber)
```
Do the same for the main-chain ASR (chain 420901) — it has its own proxy.
Then create a type-8 game (`deploy_type8 -create`) with l2block > anchor
block; the challenger validates absolutePrestate + startingRootHash and
posts an honest counter-claim if rootClaim is bogus.

### 11. Stale invalid games spam "failed to validate prestate" in challenger logs
A game created while the anchor was a sentinel will fail validation forever.
Blacklist it (guardian account calls ASR):
```
blacklistDisputeGame(address game) = 0x7d6be8dc   (guardian only)
```
Challengers that already cached the game may keep logging until restart —
harmless.

## Key ceremony (production)

**SECURITY INCIDENT: the seed generated in the agent session and all of
its derived accounts were exposed in command output and conversation history.**
They must not hold real funds, control production roles, or become multisig
signers. A new derivation index does not repair a leaked seed. Local NTFS
permissions do not establish encryption or offline custody. The key files
that were dumped to `E:\Omnicore\` (01-SEED-PHRASE … 05-CHAIN-OPS-KEYS)
were deleted on 2026-10-04; the addresses remain burned regardless —
copies may persist in backups and conversation history.

The table below is a historical incident inventory, NOT an active role
assignment. The founder's existing MetaMask address is independent of that
seed; disclosure of its public address is not a private-key compromise.

| Role (intent.toml) | Address | BIP-44 index | Custody |
|---|---|---|---|
| l1ProxyAdminOwner | `0xf4E5f55FAC40F4B834730E72Ce02371B6a37fE04` | 0 | offline seed → move to multisig |
| l2ProxyAdminOwner | `0xf4E5f55FAC40F4B834730E72Ce02371B6a37fE04` | 0 | same |
| systemConfigOwner | `0xf4E5f55FAC40F4B834730E72Ce02371B6a37fE04` | 0 | same |
| unsafeBlockSigner | `0x703AC68eEf4DD50f4436126C12cD790d24B61Aed` | 3 | sequencer host, hot |
| batcher | `0x0261943F991c1867afF4f6255A434C9c4aA3e061` | 4 | batcher host, hot |
| proposer | `0x95e2F820B424F7a870Cf81c80303b4eae5b70E3f` | 5 | proposer host, hot |
| challenger | `0x919E15F7B671B87d43f86B67e543aF3E10B4eF08` | 6 | challenger host, hot |
| Dev pool (20%) beneficiary | `0x499DE52ED1d855fb1c4f7a7a90283d8b9D385a77` | user MetaMask | user |
| Dev pool custodian key | `0x22D3659D3E0Ea3495047D6Eb0190266E791Cf436` | 1 | offline seed |
| Reserve pool (70%) beneficiary | `0xf4E5f55FAC40F4B834730E72Ce02371B6a37fE04` | 0 | governance — must be the multisig in production |
| Treasury owner | `0xf4E5f55FAC40F4B834730E72Ce02371B6a37fE04` | 0 | offline seed |
| Pool management | `0x9f83C9e92ef97881729f4760a2860fCD84f922d4` | 2 | offline seed |

### Multisig migration (before mainnet value accrues)

1. ~~Generate fresh signing material outside chat/agent tooling … deploy
   and verify a Safe~~ — **DONE 2026-10-03:** Safe `0x2F4d03593eCbA5F1B0c8491275454eCA3202AB96`
   (2-of-3: founder MetaMask `0x499D…`, production-seed `0x5505…`,
   Phantom `0xe540…`) is deployed on Ethereum mainnet. None of the
   exposed accounts is a signer; all three seeds were generated offline
   on separate devices. See `production-addresses.md`.
2. Call `transferOwnership`/ProxyAdmin `transferOwnership` pointing at the
   Safe; for `OMNICORTreasury` the Safe must then call `acceptOwnership`
   (two-step, see audit R1).
3. Update intent.toml roles for any FUTURE redeploys; existing deployed
   proxies keep their stored owners until transferred.
4. Fund hot keys with a bounded working balance; alert on balance <
   threshold (batcher/proposer/challenger burn L1 gas continuously).

### Key hygiene rules

- Never commit keys or the seed phrase to git; `.devnet-tools/` keys are
  Anvil devnet keys only and are not interchangeable with these.
- Never generate or display production seeds/private keys in agent commands.
  Do not derive cold governance and hot service roles from a shared seed.
- Use distinct hot accounts for each service AND chain. Independent transaction
  managers must not share an L1 sender without coordinated nonce management.
- Rotation requires updating the actual authorization as well as the service:
  SystemConfig gates batcher/signer; proposer and permissioned challenger
  permissions depend on the deployed game implementation and its immutable
  arguments. Verify each on-chain role after an approved migration.
- `intent.toml` is deliberately unconfigured and fails validation. Run
  `python -B omnicor/preflight.py <candidate-intent.toml>` for offline policy
  checks and `python -B -m unittest discover -s omnicor -p test_preflight.py`
  for its regression suite. Static success does not prove custody, contract
  code, the respected fault-proof path, artifact provenance or deployability;
  run the actual pinned op-deployer validation and a full testnet rehearsal.
