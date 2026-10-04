# OMNICOR contracts — line-by-line audit (2026-09-30)

Scope: `omnicor/contracts/src/*.sol` — 10 contracts, devnet rehearsal build
(`forge test`: 22/22 passing at time of audit). Audited for the taksi-platform
interface spec (two contours, burn sink, dual AMM pools, reserve treasury,
10/20/70 tokenomics).

## Verdict by contract

| Contract | Verdict | Notes |
|---|---|---|
| `OMNICORToken` | OK | Fixed 1B supply, mint-once in ctor, EIP-2612 permit (`draft-ERC20Permit`, OZ 4.x — fine) |
| `OMNIL1Bridge` | OK | Escrow; `finalizeWithdrawal` gated by `msg.sender == MESSENGER && xDomainMessageSender() == L2_BRIDGE` — the canonical pattern |
| `OMNIL2Bridge` | OK | Burns native OMNI into `LiquidityController` reserve, sends **zero-value** L2→L1 message (required by `L2ToL1MessagePasserCGT`); mint path correctly messenger-gated |
| `OMNIBurner` | OK | `burn`/`sweep`/`burnDirect` all covered; `totalBurned` cumulative counter + `Burned` event (platform spec satisfied); DEAD is an EOA so `_send` cannot revert |
| `DevVesting` | OK | 182-day cliff, 4-year linear from deploy; beneficiary-only withdrawal; immutable, no owner/upgrade path |
| `ReserveVesting` | OK | 40 quarterly tranches, linear-decay weights (40…1, sum 820), lump release at quarter start, **burn-on-expiry**: unclaimed tranche burns to `0x…dEaD` at quarter end (`burnExpired`, permissionless); `end = start + 40*90d` |
| `OMNICORTreasury` | OK + 2 recs | Owner-gated two-contour model; executor/cold wallets per spec; `receive()` accepts native funding; `topUpExecutor`/`sweepToCold` verified — see R1, R2 below |
| `WOMNI` | OK | Canonical WETH9 semantics; `withdraw` decrements balance **before** the external call (CEI-safe) |
| `SimplePair` | OK + 1 note | UniV2-compatible subset incl. pure `getAmountOut(amountIn, reserveIn, reserveOut)` (platform spec); K-check math equivalent to UniV2 — see N1 |
| `MockQuote` | OK | Open-mint, rehearsal-only; must never deploy to production (documented in contract + tokenomics.md) |

## Findings

### R1 — FIXED — `Treasury.transferOwnership` is single-step

~~A mistyped `newOwner` permanently bricks the treasury.~~ Fixed:
ownership is now two-step — `transferOwnership` nominates `pendingOwner`,
`acceptOwnership` must be called by the nominee before control moves.
`OwnershipTransferStarted`/`OwnershipTransferred` events track both legs.

### R2 — FIXED — `Treasury` has no ERC-20 rescue

Added `rescueTokens(IERC20,address,uint256)` (onlyOwner). Native OMNI is
deliberately NOT rescuable through it — it moves only via
`topUpExecutor`/`sweepToCold` so contour accounting stays meaningful.

### N1 — FIXED — `SimplePair` has no reentrancy lock

The UniV2-style `lock` modifier now guards `mint`/`burn`/`swap`/`sync`/
`skim`, so hook-bearing tokens cannot reenter the pool. (`Locked()` is
the revert reason.)

Also: `swap` pays out before the K-check (UniV2-style) — safe because a revert
undoes the whole tx, and there is deliberately no `data` callback (no flash
loans). `transferFrom` has no explicit allowance error — it underflow-reverts
safely under Solidity ≥0.8.

### N2 — INFO — vesting "quarter" convention

`ReserveVesting` uses fixed 90-day quarters: 40 tranches ≈ 3600 days
(~9.86 years), not exactly 40 calendar quarters. `DevVesting` cliff is
182 days (~6 months). Confirm the platform's tokenomics doc uses the
same convention — `tokenomics.md` states it.

### N3 — INFO — foreign-token loss in vesting contracts

`DevVesting`/`ReserveVesting` can only ever transfer `token`; any other ERC-20
or native OMNI sent to them is unrecoverable. This is intentional (immutable,
no admin keys) — document, don't "fix".

### N4 — INFO — underfunding behavior

Both vesting contracts bound `transferable()` by actual balance:
under-funding makes tranches unwithdrawable rather than minting anything.
`withdrawn` can never exceed `vested(now)`, so no underflow path exists.
Correct as designed.

## Checks performed

- Access control: messenger checks on both bridge ends (sender + xDomain
  sender), owner-only treasury ops. Vesting withdrawals are PERMISSIONLESS
  by design (post pass-4 change): any caller may trigger `withdraw`/
  `withdrawAll`, but funds can only ever go to the immutable beneficiary —
  this enables keeper-bot auto-release with zero additional trust
- Zero-amount / zero-address guards on all public entry points
- Integer math: Solidity 0.8.25 checked arithmetic; vesting formulas derived
  and verified against tranche sums (test `test_TotalEqualsAllocation`)
- Reentrancy: all external calls follow CEI or have nothing exploitable
  (see N1 for the one noted exception)
- CGT-specific: zero-value withdrawal messages; `LiquidityController.burn`
  before message emission (same-tx atomicity)
- Immutability: no proxies, no admin keys on vesting/bridges/burner
- Interface conformance vs platform spec:
  `getAmountOut(uint256,uint256,uint256)` pure ✓, `burnDirect()` payable +
  `totalBurned()` ✓, `executor(uint8)`/`coldWallet(uint8)` ✓,
  `topUpExecutor`/`sweepToCold` ✓, `NAME = "OMNICOR Treasury"` ✓

## Test coverage

39 tests across `DevVesting`, `ReserveVesting`, `OMNICORTreasury`,
`AppLayer` (WOMNI round-trip, burner accounting, pool mint/swap/K-check,
pure-quote equivalence vs reserve path, **USDT-style no-return ERC-20**
through `SafeERC20`) and withdrawal-hash vectors — all passing. Treasury
two-step ownership (R1), ERC-20 rescue (R2), the SimplePair reentrancy
lock (N1) and the ReserveVesting underfunded-to-funded transition are
now implemented and tested. No open contract findings remain.

## Runtime tooling audit (`.devnet-tools/`, `.deployer/anvil/scripts/`)

Second pass over the ops layer that drives the rehearsal (2026-09-30).

| File | Verdict | Notes |
|---|---|---|
| `auto_withdrawal.py` | FIXED + 1 note | Was stuck-waiting on `eth_getCode` at `0x8464…18bC` — a stale bridge address with no code on either chain → infinite "bridge not mined yet" loop. Now points at canonical `OMNIL2Bridge 0x948B…4F8F`. Also fixed: `batch()` lacked the reconnect/retry wrapper `rpc()` has; `eth_getProof` at `tx_block+30` could hit a not-yet-existing block — now polls for it. Note: hardcoded `KEY`/`ADDR` — rehearsal only |
| `devnet-ctl.ps1` | OK | status/stop/dedupe/start; covers WSL-side `op-reth` (`pgrep`/`pkill`). `dedupe` groups by normalized cmdline — keeps newest instance |
| `start-cgt-stack.ps1` | FIXED | Added: EL dedupe (`pgrep` before spawn — reruns used to stack duplicate op-reth), `Wait-Port` readiness gates so node/batcher/proposer no longer crash when started before anvil/beacon/EL (repeated failure mode in this rehearsal) |
| `run-cgt-el.sh` | OK + note | Native WSL op-reth launcher. `-vv` writes unbounded `/var/log/op-reth-cgt.log` — add rotation if the node runs for days. `debug`+`txpool` API on `0.0.0.0` — acceptable on the devnet host, must not be exposed beyond localhost in any real deploy |
| `monitor.py` | OK + notes | Bounded alert buffer; per-chain stall/game/vault checks correct (`gameCount()` selector `0x4d1975b4` verified). Notes: dead chains emit CRIT every 10s (no throttle/dedup); `:9717` listens on `0.0.0.0` — devnet-appropriate |
| `engine_fcu.py` | OK | HS256 JWT minted correctly (`iat`/`exp=+300s`), graceful V3→V2→V1 fallback |
| `prove_withdrawal.py` | OK (legacy) | Correct proof math; superseded by `auto_withdrawal.py`. Per-block `eth_getProof` scan from head is O(height) — use `oroot.exe` path instead |
| `finalize_withdrawal.py` | STALE | Hardcoded `R_OLD`/`R_NEW` storage roots from an earlier withdrawal — valid only for that exact chain state. Dead-code bug: `safe_head()` posts `optimism_syncStatus` to the EL port (method is op-node-only) — never called. Superseded by `auto_withdrawal.py` |
| `memcheck.ps1`, `syntax-check.ps1` | OK | New small ops helpers |
| `oroot/main.go` | OK + note | Output-root math correct (`v0‖stateRoot‖mpRoot‖blockHash`), batched scans. INFO: `-roots` empty → `segs[0]` panic; every caller supplies roots |
| `block2payload/main.go` | OK | Correct Isthmus envelope (`withdrawalsRoot` conveyed, `requestsHash` left to op-node); used for the stale-head recovery path |
| `beacon-shim/main.go` | FIXED | Two real bugs fixed: (1) blob index never reset on anvil L1 rollback — after a rewind it would serve stale blobs at reused slots (derivation-corrupting); now resets when `latest < lastIndexed`. (2) blob map grew unbounded in RAM — now pruned to newest ~3600 slots (~2h) |
| `tcprelay/main.go` | OK | Dumb bidirectional TCP proxy; used to bridge Docker containers to host loopback services |
| `start-stack.ps1` | FIXED | Same class of fix as CGT script: `Wait-Port` gates added (anvil→beacon→nodes→batcher→proposer, per-node engine RPC). Also documented why batcher follows node B |
| `start-node-c.ps1` | OK | Third sequencer candidate; static peering, dedupe-safe via devnet-ctl |
| `start-el.sh` | LEGACY | Docker-container EL path — superseded by native WSL op-reth (`run-cgt-el.sh`); kept for reference, do not use on this host |
| `redeploy-l1.sh` | OK | Deterministic op-deployer bootstrap; intent embeds correct CGT params (1B `initialLiquidity`, fast devnet dispute timings 120/60/120s) — fresh-L1 only, documented |
| `scan_claims.py` | OK + note | Correct claim↔block matching; per-block `eth_getProof` is the slow path — prefer `oroot`. INFO: `pr=None` on missing proof crashes (`storageHash` KeyError) |
| `cgt_postflush.py` | STALE | Diagnostic nonce→address dump; needs Crypto/sha3 not installed — superseded by `cast compute-address`. Hand-rolled RLP only correct for payload ≤55B (fine at our nonces) |
| `spam/main.go` | OK | Devnet load generator: N senders × K txs, measures submission + sustained drain tx/s. Used for the throughput benchmark |
| `start-challenger.sh` | OK + note | Native-WSL challenger launcher (replaced the docker path): host-gateway resolution, optional `kona-host` for cannon-kona tracing, per-chain ports/configs |

## Fourth pass — production-readiness audit (full repo sweep)

Contracts re-verified line-by-line (61/61 forge tests); all 13 Go mains,
all 11 Python utilities, every launch script, both intent files, all
address registries, monitoring rules and docs. Findings and fixes below.

### Fixed this pass

- **`l1_deploy_omni.py` — false idempotency.** Docstring promised resume,
  but `main()` aborted on any nonce > 0, so a partial deploy was
  unrecoverable. Now resumes properly: deploy steps are detected by code
  at the predicted nonce address, funding steps by vesting balance; abort
  only on true nonce drift (a foreign tx consumed a deployer nonce).
- **`check.sh` — false PASS on missing forge.** The `--contracts` step
  piped forge through `tail`, masking its exit code; a nonexistent forge
  path still produced `GATE: PASS`. Now uses `pipefail`, searches both
  the Linux and Windows mise layouts, and fails the gate when forge is
  absent.
- **`cgt_watchdog.py` — withdrawal-poller restart loop.** A dead
  `auto_withdrawal.py` was restarted unconditionally; every launch
  performs a real 10-OMNI `withdrawTo`, so a crashed-and-restarted
  poller drained escrow in 10-OMNI increments each cycle. Now checks the
  poller log tail for `=== DONE ===`/`FATAL` and stays down in both
  cases (completed run must not re-fire; FATAL needs human triage).
- **`cgt_watchdog.py` — ghost-parent recovery was dead code.**
  `reset_node()` existed but was never called; the "unsafe head stalled"
  failure mode (strike 1: `admin_resetDerivationPipeline`, strike 2:
  wipe safedb + restart) is now wired with a 20-minute cooldown.
- **`monitor.py` — alert spam.** Unsafe-stall, safe-stall and
  game-inactivity alerts re-fired every 10 s poll while the condition
  persisted. Now edge-triggered with dedup flags, matching the existing
  `el_down`/`drift`/`fork` alert pattern.
- **`tcprelay` — no half-close propagation.** `io.Copy` finished without
  a FIN to the peer, so protocols that read a request until EOF could
  hang. `CloseWrite` now propagates on both directions (TCP only; no-op
  otherwise).
- **`cgt_redeploy_v2.py` — stale production comments.** LP-holder and
  treasury-owner comments pointed at obsolete rehearsal addresses
  (`0x9f83…`, `0xf4E5…`); now reference Pool Mgmt `0x5505…` and the
  treasury Safe `0x2F4d…`.
- **`devnet-ctl.ps1` — stale kill patterns.** Removed patterns for
  deleted scripts (`finalize_withdrawal.py`, `prove_withdrawal.py`,
  `cgt_postflush.py`); added `cgt_watchdog.py`.

### Confirmed correct (no change needed)

- All 10 contracts: access control, zero-value CGT withdrawal messages,
  CEI ordering, immutability of vesting beneficiaries, tranche math
  (40…1 = 820 weight, 90-day quarters ≈ 9.86 years — documented
  convention) plus the expiry-burn accounting in `ReserveVesting`.
- Upstream patches (raft FSM error propagation, snapshot validation,
  embedded FS paths, `op-up --block-time`) — all sound.
- `intent.toml` (prod template) is intentionally fail-closed;
  `preflight.py` + 9 unittests enforce it.
- Devnet `intent.toml` uses Anvil keys and accelerated dispute windows —
  correct for rehearsal only.
- `app-addresses.json` `l1_bridge == OMNI_RU_PAIR` is a **coincidental
  nonce collision** (L1 nonce 19 vs L2 nonce 19 under the same deployer),
  not a wiring bug — but it is fragile and deserves a comment if the
  registry is ever regenerated.

### Known limitations (documented, accepted for devnet)

- `prometheus.yml` has **no Alertmanager routing** — alerts are visible
  in Prometheus but do not page anyone. Production blocker until a
  receiver (PagerDuty/Telegram/webhook) is configured.
- `monitor.py` binds `:9717` on `0.0.0.0` and reads devnet topology
  paths — devnet-only.
- `SimplePair` has no TWAP/oracle; `getReserves`-based price views are
  sandwich-manipulable — fine for rehearsal, not a production oracle.
- `beacon-shim` slot 0 log line when `!slotOK` — cosmetic.
- `scan_claims.py` crashes on a missing proof (`pr=None`) — devnet
  diagnostic only.
- Hardcoded Anvil keys across scripts — devnet-only, never reuse.
  `l1_deploy_omni.py` prod mode takes the key from env, writes nothing
  to disk.

### Production blockers (pre-launch, by design)

1. External audit of the 10-contract suite + deploy pipeline.
2. Testnet rehearsal of the full L1 deploy with the real Safe.
3. On-chain verification of the Safe (owners, threshold, chain) before
   it is wired as `RESERVE_BENEFICIARY`.
4. Fault-proof game rehearsal end-to-end (propose → challenge →
   resolve) at production timings, not the devnet 120/60/120 s windows.
5. Alertmanager + paging path.
6. Fee-vault routing: only `BaseFeeVault` → `OMNIBurner` is wired on
   devnet; remaining vaults need production routing + verification.
   `FeeSplitter` (immutable 70% burn / 30% treasury) is now the
   designated production recipient — deploy at app-layer b+9 and point
   all four vaults at it.

## Fifth pass — pre-deploy final audit (2026-10-04)

Scope: every change since the fourth pass — `FeeSplitter`, the
`ReserveVesting` quarterly rewrite (claim windows + burn-on-expiry +
inline settle on claim), `vesting_keeper` (burn + splitter sweeps),
`cex_burn_bot`, `revenue_burn`, `update_taksi_env`, deploy scripts.

Findings — all fixed:

1. **ReserveVesting: permanently locked remainder.** The 40 tranches
   sum to `allocation` minus rounding dust, and any tokens sent to the
   contract by mistake could never be claimed or burned — locked
   forever. Fix: once every tranche period has ended, `_burnExpired`
   sweeps the entire leftover balance to `0x…dEaD`.
   Tests: `test_MistakenTokensSweptAfterEnd`, exact-balance check in
   `test_EverythingUnclaimedBurnsAfterEnd`.
2. **vesting_keeper: unconditional `burnExpired` tx every poll.** A
   no-op settle tx still costs real L1 gas every 6h forever. Fix:
   pre-check `nextBurnPeriod()` vs `periodAt(now)` via `eth_call`;
   the settle tx is only sent when a quarter actually expired.
3. **update_taksi_env.py: hard crash on the current registry.**
   `reg["splitter"]` raised `KeyError` because the existing
   `app-addresses.json` predates the splitter deploy — the whole env
   render died. Fix: missing registry keys warn-and-skip. Also the
   `OMNI_FEE_SPLITTER_ADDRESS` env line had no `0x…` placeholder, so
   the patch regex could never match it — placeholder is now the zero
   address and gets rewritten on redeploy.
4. **revenue_burn.py: float64 wei conversion.** `int(burn * 1e18)`
   lost up to ~4×10⁸ wei on million-OMNI amounts — the Safe calldata
   would carry a slightly wrong amount. Fix: exact `Decimal` math,
   ROUND_DOWN integral conversion.
5. **redeploy_cgt_app.py: superseded deployer.** Running it produces
   an app layer without `FeeSplitter`/`OMNICORTreasury` and an
   incompatible nonce set. Marked deprecated in the docstring.
6. vesting_keeper: pyflakes f-string warning — cleaned.

Findings — second round (same pass):

7. **vesting_keeper: `burnExpired` unreachable when transferable==0.**
   The expiry-settle check sat behind `if amt < MIN_SWEEP_WEI:
   continue` — so after the last quarter ends (transferable is 0
   forever) the keeper would never trigger the final leftover sweep,
   and mid-schedule deferred burns only happened incidentally on the
   next claim. Fix: the `burnExpired` pre-check now runs independently
   of `withdrawAll`, and is only skipped when a successful
   `withdrawAll` already settled expiry inline that round.
8. **cex_burn_bot: no burn-window gating.** The daily loop withdrew
   the entire free OMNI balance every day — mid-quarter that pulls the
   tranche that is still trading. Fix: `CEX_BURN_QUARTER_EPOCH` +
   `CEX_BURN_WINDOW_DAYS` gate `--exec` runs to the last days of each
   90-day quarter; `--force` overrides for manual ops; unset epoch
   means never fire.
9. **cex_burn_bot: no crash-resume.** A restart after submitting a
   withdrawal could submit a duplicate. Fix: pending withdrawal id
   persisted in a state file; it is polled to a terminal state before
   any new withdrawal is attempted.
10. **cex_burn_bot: float amounts + no HTTP retry.** Balances are now
    `Decimal` (a 34M-OMNI float loses sub-unit precision), and
    `_req` retries 429/5xx/timeouts with backoff and surfaces MEXC
    error bodies instead of bare HTTPError.
11. **revenue_burn: no input validation.** Negative `--rub`, zero
    `--price`, or `--burn-bps >10000` produced nonsense or negative-wei
    calldata. Args now parse as `Decimal` with range checks.
12. cgt_redeploy_v2 nonce math re-verified: splitter at b+9 between
    treasury (b+8) and seeding (b+10..b+18), resume scan window
    `base-19..base` covers all 19 txs, semantic check asserts
    `splitter.BURNER/TREASURY/BURN_BPS`. Registry keys `splitter`
    present; `app-addresses.json` predates it (warn-and-skip, fills on
    next redeploy).

Policy decision (owner, 2026-10-04): the debt ledger FIXES the OMNI
amount of each obligation at the OMNI/RUB rate on the day the debt is
recorded — no settlement-day repricing. Consequence: the ledger's
period report is already OMNI-denominated and `revenue_burn.py --omni`
burns exactly that sum. `--rub`/`--price` stays as a manual conversion
mode only. This removes the open question flagged in earlier passes —
the platform bears rate drift between record and settlement, the burn
amount is deterministic and auditable per record.

Verified clean (no change needed):

- `FeeSplitter.sweep()` — counters/event emitted before external
  calls; balance is already 0 when `TREASURY.call` executes, so a
  re-entrant `sweep()` reverts `NothingToSplit`; destinations are
  immutable, caller cannot redirect.
- `ReserveVesting` claim window: `periodAt` boundary math checked at
  exact quarter edges; `transferable()` bounded by `tranche` AND
  balance; expired tranches unclaimable under late funding;
  `_burnExpired` idempotent (double call = no-op); under-funded burn
  settles `min(remainder, balance)` and never resurrects.
- `DevVesting`, `OMNIL1Bridge`, `OMNIL2Bridge`, `OMNICORToken` —
  unchanged since audit; constructor signature of `ReserveVesting` is
  unchanged so `l1_deploy_omni.py` requires no edits.
- `auto_withdrawal.py` is the bridge E2E tool, not vesting — no
  automation conflict with the keeper.

Test totals: **73/73 forge tests green** (+12 vs fourth pass —
FeeSplitter suite, quarterly vesting rewrite, expiry-burn edges).

### Process-hygiene findings (fixed during rehearsal)

- Duplicate `auto_withdrawal.py` instances accumulated across restarts
  (5 killed at once on 2026-09-30). `devnet-ctl dedupe` now covers it;
  scripts that spawn long-running python pollers must go through it.
- `op-node`/`op-batcher`/`op-proposer` started before anvil/beacon/EL
  died silently — root cause of several "stack half-dead" states.
  Now gated by `Wait-Port` in `start-cgt-stack.ps1`; same treatment is
  recommended for `start-stack.ps1`/`start-node-c.ps1` (420901 side).
- Docker Desktop was eliminated from the CGT path (OOM source on the
  8GB host): op-reth runs natively in WSL Ubuntu, datadir exported to
  ext4 `/var/lib/omnicor-el/cgt`. 420901 migration to the same pattern
  is planned.

## Sixth pass — TAKSI seam audit (2026-10-04)

Full read of the platform integration layer (`omnilink` ~2.6k LOC on
the taksi-platform side): debt-book writes, rate-source hierarchy,
`format=ledger`/`run` exports, `VerifySettlement` on-chain check,
claim idempotency — ABI verified selector-by-selector against the
deployed contracts.

Findings (both fixed):

1. **Double-burn via overlapping exports** (platform d5a96bf). An open
   `?format=ledger` export included records already claimed by an
   active settlement run — the same records `?run=<id>` exports.
   Burning both payloads burns twice; burning only the open export
   leaves `VerifySettlement` with an AMOUNT MISMATCH against the run.
   Fix: open exports now exclude records held by active runs and carry
   `in_settlement_runs` (pending run ids) plus a `note` marking the
   view as audit-only — real burns go through `?run=`.
2. **L1 verify env not emitted** (omnicor 6eb5ea3dd9). The platform
   reads `OMNI_L1_RPC_URL`/`OMNI_L1_TOKEN` for
   `/admin/omni/run/settle`, but neither `taksi.env.example` nor
   `update_taksi_env.py` produced them — an operator would have had to
   discover the variables by hand. Both templates now emit the
   canonical values.

Verified clean: `price0()`/`token0()`/`getAmountOut(uint256,address)`
pool ABI, `burnDirect()`/`totalBurned()`/`sweep()`/`totalToTreasury()`
call sites, UNIQUE(payment_id) claim idempotency, interrupted-run
policy (never auto-released), `rate_src` audit labels including
`reprice_*` fallbacks.

## Out of scope

OP Stack predeploys and L1 system contracts (upstream audit coverage),
op-node/op-batcher/op-proposer Go code, the intent/rollup config.
