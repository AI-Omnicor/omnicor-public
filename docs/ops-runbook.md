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

### 4. op-node init "Walking back L1Block" for a very long time
FindL2Heads traverses unsafe→safe on every start; with a large
unsafe−safe gap this takes ~1.5 blk/s. Faster: unwind the EL so unsafe≈safe
first (see §3), or copy a healthy peer's `safedb` directory while both nodes
are stopped.

### 5. rollup-boost EOF / ServiceUnavailable gating engine calls
Boost marks itself unhealthy when the EL's unsafe timestamp is stale and can
EOF op-node's init queries → deadlock (node can't init because boost won't
serve because head is stale). Fix: point the node's `--l2` directly at the EL
authrpc port until the head is fresh, then repoint to boost.
Also: `rollup-boost v0.7.17` `--ignore-unhealthy-builders` semantics are
inverted vs docs — with the flag set, FCU to an unhealthy builder is SKIPPED
(deadlock). Run without it.

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

## Verification checklist (post-recovery)

- `optimism_syncStatus` on 9647/9747/10047: identical unsafe/safe/finalized
- exactly one `conductor_leader=true` across 7545/7645/7845
- `conductor_clusterMembership` shows all 3 voters
- EL latest block timestamp age < 5 s (sequencing live)
- `curl ws probe` on the leader's fb port (8400/8401/8402)
- preconf e2e: accepted < 100 ms, flashblock < 500 ms, confirmed ~1 s

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
