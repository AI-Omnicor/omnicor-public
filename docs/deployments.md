# OMNICOR Deployments

> **READ THIS FIRST — canonical current state.** This file is a chronological
> log; many sections describe older chain incarnations whose contracts no
> longer exist on the live L1. The only authoritative addresses are:
>
> | Component | Where to look |
> |---|---|
> | L1 app layer (OMNI token, L1 bridge, vestings) | live probes in `verify-stack.ps1` + the "Vesting beneficiaries (corrected 2026-10-02)" section below |
> | L2 app layer (CGT chain 420902) | `.deployer/anvil/app-addresses.json` |
> | Portals (per chain) | `deposit_contract_address` in `.deployer/anvil/rollup{,-cgt}.json` |
> | DisputeGameFactory per chain | `topology.psd1` (`MainDgf`, `Cgt.Dgf`) |
> | Ports/nodes/conductors | `topology.psd1` |
>
> Every address in the historical sections below is superseded unless it
> also appears in one of those sources. Never copy an address from prose —
> verify with `cast code` against the live RPC first.

## Devnet (op-up, Docker container `omnicor-devnet`)

- L2 chain ID: **901** | RPC: `http://localhost:8545` (1s blocks, 60M gas limit)
- Test account: `0x5D284fe6D6AEb73857960a0D041CF394b1198392`
  (devnet key, printed by op-up — never reuse outside devnet)

| Contract | Address | Tx |
|---|---|---|
| OMNICORToken (OMNI, 1B supply) | `0x769CD0FBd76B399cfD78CF280E86Ed674236C17E` | `0x018ce30e…` |
| DevVesting (20% = 200M OMNI locked) | `0x2BBC2a56c609035676AcBcb908443A856EfEf4f7` | `0x34d6b47c…` |

Verified on-chain:
- `DevVesting.transferable() == 0` — allocation frozen
- `unlockTime() = 1948105583` (~Sep 2031 — 5-year cliff)
- `token.balanceOf(vesting) = 200_000_000e18`
- `withdraw(1000)` reverts with `StillLocked` ✓

MetaMask: import `OMNI` by token address on chain 901.

## Full deployment rehearsal (anvil L1 + real op-node/op-reth/op-batcher)

A complete OP Stack deployment was rehearsed locally — not in-memory, a real
L1 contract suite deployed via `op-deployer` and a live sequencer/batcher
pipeline. Workdir: `.deployer/anvil/` (gitignored, contains dev keys).

**L1 (anvil, chain 31337, `http://localhost:9545`, NATIVE process with
`--state .deployer/anvil/l1-state.json` — survives Docker restarts;
replay `.deployer/anvil/scripts/redeploy-l1.sh` after a wipe)**

- `bootstrap superchain` → SuperchainConfigProxy `0x9fe46736…7fa6e0`,
  ProxyAdmin `0x5fbdb231…80aa3` (deterministic across redeploys)
- `bootstrap implementations` → OPCMV2 `0xa6e9b3b8…95c86d` + all impls
- `apply` (intent `configType=custom`, opcmAddress+superchainConfigProxy set)
  → OP Chain 420901 (redeployed 2026-09-27 after Docker wipe): OptimismPortal
  `0xE981E822…f0ebed`, SystemConfig `0x7A782e71…74f08`, DisputeGameFactory
  `0x271bE531…240d2b`, AnchorStateRegistry `0x324117D3…6175a9`,
  MIPS `0xacC005dC…825cfa`, PreimageOracle `0x1e1d7353…0aeb1e0` — full suite;
  live addresses in `.deployer/anvil/state.json`

**L2 stack**

- op-reth (container `omnicor-l2`, named volume `omnicor-reth-data`):
  RPC `localhost:8645`, authRPC `8651` — debug binary at
  `rust/target/debug/op-reth`; release build in
  `rust/target/release/op-reth` swaps in for the throughput ceiling
  (debug build caps ~1.3k tx / 27 Mgas per 1s block)
- op-node.exe (Windows, sequencer): rollup.json `block_time=1`, all forks
  at genesis, `--p2p.disable`, RPC `localhost:9647`
- op-batcher.exe: **EIP-4844 blob DA** (`--data-availability-type=blobs`,
  zlib ~0.77 ratio) → L1; blobs served to op-node by the local beacon shim
  (`.devnet-tools/beacon-shim`, container `omnicor-beacon-shim` :5052,
  `--seconds-per-slot=2`)

**Tokenomics on chain 420901** (v2 — linear vesting, deployed 2026-09-27)

| Contract | Address | Tx |
|---|---|---|
| OMNICORToken v2 (OMNI, 1B supply) | `0x59F2f1fCfE2474fD5F0b9BA1E73ca90b143Eb8d0` | `0xbec3f978…` |
| DevVesting v2 (20% = 200M OMNI, beneficiary `0x499DE52ED1d855fb1c4f7a7a90283d8b9D385a77`) | `0x05Aa229Aec102f78CE0E852A812a388F076Aa555` | `0xe19e0516…` |

Schedule: 182-day cliff → ~12.5% (25M OMNI) unlocks at once, then linear
vesting over 4 years total (~4.17M OMNI/month, withdrawable any time).
`end() = 1916579355` (full vest ~Sep 2030). Verified: vesting holds
`200_000_000e18` OMNI, `transferable() == 0`, `beneficiary()` = founder
wallet (immutable). Founder wallet funded with 5 L2 ETH for MetaMask
testing (add network: RPC `http://localhost:8645`, chain ID `420901`,
then import token `0x59F2…Eb8d0`).

Superseded test artifacts (v1 with the old 5y-cliff contract — ignore):
token `0x71C95911…3292e`, vesting `0x948B3c65…34F8F`, plus two probe
deploys (`0xC6bA8C32…EdD2` dummy vesting, `0x1275D096…2487` vesting that
mistakenly referenced the dummy instead of the token).

**Verified end-to-end**

- L2 blocks at 1s cadence; unsafe=1834, safe=1820, finalized=1567 while observed
- L1→L2 deposit via `OptimismPortal.depositTransaction` landed on L2
- Burst: **1301 tx in a single 1s block = 27.35 Mgas/s** (limit 60M, 45% used);
  2000 tx drained in 2 blocks (~1000 TPS effective)
- **Sustained** (150 senders, 12000 tx): submission 2055 tx/s; **7 consecutive
  full blocks at exactly 1301 tx / 27.35 Mgas/s each** — a deterministic
  payload-builder plateau, not the 60M gas limit. Raising it is a reth
  builder-budget question (investigate `--builder.*` / payload sizing).
- RPC latency ~6-14 ms (same as devnet)
- Batcher needs `--max-channel-duration` on 1s chains: with
  `target_num_frames=1` + zlib, empty-ish blocks take ~1200+ blocks to fill a
  120KB frame, so safe head stalls. `15` closes channels every ~15 L1 blocks.

**Fault proofs (verified end-to-end)**

- Respected game type: **5 = SUPER_PERMISSIONED** (super-root games;
  `AnchorStateRegistry.respectedGameType() == 5`, impl `0x5C3e…D691`)
- **op-proposer** runs with `--game-type=5 --superroot-rpcs=http://localhost:9647`
  — op-node itself serves `superroot_atTimestamp` for the single chain
  (requires `--safedb.path`, otherwise proposals fail with
  "safe head database not enabled")
- Super-permissioned games resolve immediately as `DEFENDER_WINS` after
  on-chain checks: `rootClaim == hashSuperRootProof(extraData)`,
  `tx.origin == proposer`, `l2SequenceNumber > anchor`
- **Anchor progression**: after `disputeGameFinalityDelaySeconds` (302400s =
  3.5d — standard prod value, warped on anvil via `evm_increaseTime`),
  `AnchorStateRegistry.setAnchorState(game)` advanced `getAnchorRoot()` from
  `0xdead…` placeholder to `0xb5eaf6…` (seq 1790429429)
- **Withdrawal L2→L1 proven and finalized**: `initiateWithdrawal` (0.05 ETH,
  L2 block 2861) → manual `DGF.create(type 5)` game at ts 1790430690 →
  `proveWithdrawalTransaction` (WithdrawalProven) → warp 7d
  (`proofMaturityDelaySeconds = 604800`) → `finalizeWithdrawalTransaction`
  credited the L1 account (+0.05 ETH − gas)
- **Disaster recovery verified**: op-reth container was deleted — L2 state
  lost entirely. After restart, op-node re-derived the full chain from L1
  batches: block 2861 hash identical (`0xcacf007f…`), all dispute games
  remained valid, sequencing resumed (unsafe 3999+). L1 DA = full L2 recovery.
- Known rehearsal quirk: `eth_getProof` needs
  `--rpc.eth-proof-window 1209600` on op-reth (default window rejects proofs
  beyond ~recent tip); proposer interval logic reads L1 timestamps, so anvil
  `evm_increaseTime` warps stall it until restart.

**Withdrawal E2E with real value (second deployment)**

- Full cycle on the redeployed stack: `initiateWithdrawal` 0.1 ETH (L2 block
  3582) → batcher → safe → manual `DGF.create` super game (index 5,
  `rootClaim = superroot` from `superroot_atTimestamp`, extraData =
  `0x01 || uint64 ts || uint256 chainId || bytes32 outputRoot`) →
  `resolve()` → `DEFENDER_WINS` → `AnchorStateRegistry.isGameClaimValid=true`
  → `proveWithdrawalTransaction` → warp `proofMaturityDelaySeconds` →
  `finalizeWithdrawalTransaction` → **+0.1 ETH actually received on L1**
  (`WithdrawalFinalized success=true`).
- Gotcha discovered: `WithdrawalFinalized(..., success=false)` does NOT
  revert — the finalize tx succeeds even when the portal holds no ETH.
  Always fund the portal (deposits/lockbox) before expecting payouts.

**OMNI withdrawal E2E with real value (third deployment, CGT chain 420902)**

- Full app-layer cycle on the fresh OP Stack deploy (all contracts under
  `.deployer/anvil/state.json`, DGF `0x0431c7c50b5ff6f5bd3d6d7c4e1a0e485bb57877`,
  Portal `0x31dd9ecc3dbf66ec7c95cca5bce41679231dc8f6`):
  `OMNIL2Bridge.withdrawTo(10 OMNI)` at L2 block 3382 (wh `0xe9725ac6…`) →
  batcher (corrected key → authorized submitter, safe head advanced past the
  block) → proposer auto-created super-game #1 (`claim block 3447 ≥ 3382`) →
  `proveWithdrawalTransaction` status 1 → `resolve()` status 1 →
  `evm_increaseTime(605500)` (fresh deploy uses production-length timers:
  `proofMaturityDelaySeconds=604800`, `disputeGameFinalityDelaySeconds=302400`)
  → `finalizeWithdrawalTransaction` status 1.
- **Two failure modes hit and solved**: (a) inner `relayMessage` to
  `OMNIL1Bridge.finalizeWithdrawal` reverted — the L1 escrow bridge held no
  OMNI (it only gets funded by real L1→L2 deposits); emitted
  `FailedRelayedMessage` while the portal still reported `success=1`.
  Funded the bridge (`transfer 100 OMNI`) then re-called
  `relayMessage` — FailedRelayedMessage again because `cast` gas
  estimation ran the inner call at ~78k gas (OOG). Replayed with explicit
  `--gas-limit 500000` → `RelayedMessage` + `WithdrawalFinalized` +
  `TRANSFER 10 OMNI` to the recipient. L1 OMNI balance delta confirmed:
  `100,000,000 → 99,999,910` (−100 bridge funding, +10 withdrawal payout).
- Ops rules learned: (1) always keep the L1 bridge escrow funded or
  deposits-backed before withdrawals; (2) failed relayed messages are
  replayable via `L1Messenger.relayMessage` with identical params —
  override gas manually; (3) devnet intend short dispute timers via
  intent overrides, otherwise use `evm_increaseTime`.

**op-dispute-mon (live)**

- Built for Linux (`./bin/op-dispute-mon`, `golang:1.26` container — does not
  compile natively on Windows), running as `omnicor-disputemon`, metrics on
  `:7300`. Monitors factory `0x0e2b…5d41`, honest actors = proposer +
  challenger keys. All 6 games reported `agree_defender_wins` /
  `root_agreement=agree` — the monitor independently recomputes super roots
  via `--superroot-rpc=op-node:9647`.

**Blob DA (live)**

- Wrote `.devnet-tools/beacon-shim` — a minimal Beacon-API bridge for anvil:
  anvil accepts EIP-4844 txs and retains full sidecars retrievable via
  `eth_getTransactionByHash`; the shim indexes blob txs per slot and serves
  `eth/v1/beacon/genesis` + `eth/v1/beacon/blobs/{slot}` (the only endpoints
  op-node's `L1BeaconClient` needs when `--l1.beacon.slot-duration-override`
  is set). genesis_time = anvil block 0 ts, SECONDS_PER_SLOT = 2.
- op-node restarted with `--l1.beacon=http://localhost:5052
  --l1.beacon.slot-duration-override=2` (was `--l1.beacon.ignore`);
  op-batcher with `--data-availability-type=blobs`. Verified: batcher
  publishes 1-blob txs every ~15 L1 blocks, shim indexes them, op-node
  derives (safe head keeps advancing, no blob-fetch errors).

**Caveats**: permissionless CANNON_KONA (type 8) not yet deployed — needs a
reproducible kona prestate build for chain 420901 (build in progress);
anvil dev keys everywhere; `.devnet-tools` is gitignored (devnet-only
helpers).

## Fresh devnet (2026-09-28, `.deployer/anvil/`, two-chain intent)

Clean redeploy after L1 timeline corruption. `op-deployer apply` produced
**two chains in one apply** (`redeploy-l1.sh` + `intent.toml`):
420901 (standard, ETH gas) and 420902 (CGT, OMNI gas). L2 genesis L1 origin = block 80.

**L1 contracts (anvil 31337, RPC :9545):**

| Chain 420901 | Address |
|---|---|
| OptimismPortalProxy | `0x80bfe2bf61d42e7abe2e4546c6bd8f28e1af6866` |
| SystemConfigProxy | `0xb60307146780c0de07eb8eb012d78a8d65590d60` |
| DisputeGameFactoryProxy | `0x2c0fa2f5bf8e6ec9047b6d10eb522fa813be56a5` |
| AnchorStateRegistryProxy | `0xb63f317c6e50bdcd000a1ebf26d4079a5a5640b5` |
| L1CrossDomainMessengerProxy | `0xffd29812e452d3a2bcd3807855153ffe84db2f6d` |
| L1StandardBridgeProxy | `0x0441b06a40f55a99b970d49f13ed1e34f936ed8c` |
| DelayedWETH | `0x1cfc5d3e1e6948d42c8031f16f444301bae5e13f` |

| Chain 420902 (CGT) | Address |
|---|---|
| OptimismPortalProxy | `0x15db59d878d1543819bf1deb3caf4408d1622590` |
| SystemConfigProxy (`isCustomGasToken()=true`) | `0xe03ea65ef84277fb4d388200d721ebfc76b965aa` |
| DisputeGameFactoryProxy | `0xd11ad4e5fe5f118f91c7dfda9fd29a6fba8440dc` |
| AnchorStateRegistryProxy | `0xf0446186dfe7511d5fdde67eea3b30cec46d80c8` |
| L1CrossDomainMessengerProxy | `0x0866e363c9d5031d42636f4f4186cd8dc8db03d2` |
| DelayedWETH | `0x708e05ca4ef99c6829b1a005f567f166e65a381f` |

Shared implementations: MIPS `0xacc005dcd857b401e4732e6f7837135a22825cfa`,
FaultDisputeGame `0x2dda3584b51ef5236f7726dea5a0fb6b3ca94aec`,
SuperPermissionedDisputeGame `0x5c3eb47cb0174aea522a2a9ae79487139a53d691`
(registered as `gameImpls[5]` — the respected type on both portals).

**OMNI L1 token + app bridges (redeployed 2026-10-02, deployer 0x7099…79c8):**
OMNI ERC-20 `0x948B3c65b89DF0B4894ABE91E6D02FE579834F8F` (1B to deployer),
`OMNIL1Bridge` `0x85C5Dd61585773423e378146D4bEC6f8D149E248` (rebound to
the live L2 bridge),
`OMNIL2Bridge` `0x2dE080e97B0caE9825375D31f5D0eD5751fDf16D` (minter in
LiquidityController). The previous L1 bridge `0x712516e6…B03e` points at
the unreachable nonce-0 L2 address — do not deposit through it.

**Vesting beneficiaries (corrected 2026-10-02):** `DevVesting`
`0x8464135c8F25Da09e49BC8782676a84730C318bC` (200M, beneficiary = founder
`0x499DE52E…5a77`) unchanged. The original `ReserveVesting`
`0x71C95911…292e` mistakenly vested the 700M reserve to the same founder
wallet — superseded by `0x2fc631e4B3018258759C52AF169200213e84ABab`
(beneficiary = treasury/governance key `0xf4E5f55F…fE04`, seed index 0;
multisig in production). The 700M balance was moved via devnet storage
surgery (`anvil_setStorageAt` on the token's `_balances` slots); the old
contract is now an empty shell — do not treat it as canonical.

CGT `OMNICORTreasury` `0xAfe1b5bd…d44b` ownership was also transferred
from the deployer to the treasury key `0xf4E5f55F…fE04` (two-step
transfer → accept, tx `0x71e092d5…`) so devnet custody mirrors the
production role model.

**Kona prestates (built with both chains in the custom registry — fresh
genesis hashes):** cannon `0x033547108e4950794b9ba372931822ad51beb93df22bb46fd24c8bc0e15395e1`,
interop `0x03ab953f4e984dd0b055a1116eb8bec0f7423380de250c6d8c2b66e3fc9a2add`.
Artifacts exported to `.deployer/anvil/prestate-export/prestate-artifacts-cannon{,-interop}/`.

**CANNON_KONA (type 8) registered on BOTH DGFs** via
`setImplementation(8, 0x2dda3584…, gameArgs)` with `gameArgs` =
`prestate 0x0335471… | MIPS | chain ASR | chain WETH | l2ChainId`
(txs `0xd5662b16…` on 420901's DGF, `0x41ab0df1…` on 420902's DGF).
respectedGameType stays 5 until the challenger fleet runs.

**Runtime layout:**

- 420901 ELs: `omnicor-l2` :8645/8651, `omnicor-l2-b` :8745/8751,
  `omnicor-l2-c` :8945/8951 (third replica for HA)
- 420901 op-nodes: A :9647 (p2p 9003), B :9747 (p2p 9004), T :10047 (p2p 9006)
- 420901 conductors: c1 :7545 (raft 50050), c2 :7645 (raft 50051), c3 :7845 (raft 50053)
- 420901 batcher :9648, proposer :9649 (super-root via :9647, type 5)
- 420902 EL: op-reth нативно в WSL Ubuntu :8845/8851 (:8846 ws) —
  **без Docker Desktop** (OOM на 8GB-хосте). Datadir внутри WSL ext4:
  `/var/lib/omnicor-el/cgt` (экспортирован из docker-volume 2026-09-30,
  копия также в `.deployer/anvil/eldata/cgt`). Лаунчер:
  `.devnet-tools/run-cgt-el.sh`; старт через
  `start-cgt-stack.ps1 -Phase el` (wsl -d Ubuntu). Лог
  `/var/log/op-reth-cgt.log` внутри Ubuntu. Порты пробрасываются на
  Windows localhost через WSL localhostForwarding.
  single sequencer op-node :9847 (no conductor — conductor healthcheck
  requires ≥1 CL peer); batcher :9848, proposer :9849
- 420901 ELs так же мигрируют в WSL при следующем запуске (объёмы
  `omnicor-l2{,-b,-c}-data` → `/var/lib/omnicor-el/{a,b,t}`)
- Scripts: `start-stack.ps1` (420901), `start-cgt-stack.ps1` (420902),
  `start-node-c.ps1` (third 420901 node), `start-el.sh` (EL containers)
- Monitoring: `.devnet-tools/monitor.py` → Prometheus metrics + alerts on
  `localhost:9717` (`/metrics`, `/alerts`), log `monitor.log`

## CGT rehearsal — OMNI as native gas (chain 420902)

Workdir `.deployer/anvil-cgt/` (gitignored). Intent
`.deployer/anvil-cgt/intent.toml`: `blockTime=1`, `l2GasLimit=60M`,
`minBaseFee=0`, `[chains.customGasToken]` name="OMNICOR" symbol="OMNI",
`initialLiquidity=1e27` (1B), `liquidityControllerOwner=L2PAO`,
`dangerousUseSystemConfigFusedBridges=false` (CGT v2 mode).

**L1 side (anvil 31337, native process — same L1 as the 420901 rehearsal):**
OMNI ERC-20 `0x851356ae760d987e095750cceb3bc6014560891c`,
`OMNIL1Bridge` `0x95401dc811bb5740090279Ba06cfA8fcF6113778`,
portal `0xc250d9f65b0dc58415d2d042eadaa16225780794`,
L1CrossDomainMessenger `0x03809a2643aea02b95cb4840e58c7e1665aa0fe7`,
SystemConfig `0x6783b93e22ee3e5fb83818de6de31fc162ef4851`
(`isCustomGasToken() = true`), DGF `0xe4a64aeea321aa496e08f2325e420a3cc9e63bc3`,
AnchorStateRegistry `0x64bddee32bb5e6b5159a0e08e6459c2c45e7d0dc`.

**L2 side (op-reth container `omnicor-l2-cgt`, RPC `localhost:8845`,
authRPC 8851; op-node RPC `9847`; batcher `9848`; proposer `9849`;
canonical sibling-node port split `../anvil/scripts/start-stack.ps1`):**
`NativeAssetLiquidity` `0x4200…0029` holds 1e27 wei OMNI;
`LiquidityController` `0x4200…002A` (minter: OMNIL2Bridge);
gasPayingToken = ("OMNICOR","OMNI").

**App-layer contracts (`omnicor/contracts/`, deployed by L2 dev wallet
`0x7099…79c8` at base nonce 41, 2026-10-08 — via
`.devnet-tools/cgt_redeploy_v3.py`). AMM is now the canonical Uniswap V2
port (`src/univ2/`): Factory+Pair+Router02, CREATE2 pairs, 0.3% fee,
TWAP accumulators, flash-swap callback, optional 1/6 protocol fee:**

| Contract | Address |
|---|---|
| `OMNIL2Bridge` | `0x7290f72B5C67052DDE8e6E179F7803c493e90d3f` |
| `WOMNI` | `0xc63d2a04762529edB649d7a4cC3E57A0085e8544` |
| `MockQuote` (rRUB) | `0x1a6a3e7Bb246158dF31d8f924B84D961669Ba4e5` |
| `MockQuote` (USDT) | `0x093e8F4d8f267d2CeEc9eB889E2054710d187beD` |
| `OMNIBurner` | `0xBa3e08b4753E68952031102518379ED2fDADcA30` |
| `UniswapV2Factory` (feeToSetter=deployer) | `0x34ee84036C47d852901b7069aBD80171D9A489a6` |
| `UniswapV2Router02` (factory, WOMNI) | `0xa85b028984bC54A2a3D844B070544F59dDDf89DE` |
| `UniswapV2Pair` WOMNI/rRUB = `OMNI_RU_PAIR` | `0x2e79fb9360d8a45383939877bcf9ce9048f54439` |
| `UniswapV2Pair` WOMNI/USDT = `OMNI_INTL_PAIR` | `0x37c0a78e8d5a0f7487ec26a45ad5c41ac01c349c` |
| `OMNICORTreasury` | `0x23d351BA89eaAc4E328133Cb48e050064C219A1E` |
| `FeeSplitter` | `0x35D2F51DBC8b401B11fA3FE04423E0f5cd9fEDb4` |

Pair addresses are CREATE2-derived (factory + sorted tokens +
`keccak256(UniswapV2Pair.creationCode)` = `0x1b3e550a5ef6896f35b0c6357080
31fc875929b1bb2ef4117191a9e8cf6ac079` for this solc-0.8.25 build) — the
canonical upstream constant `0x96e8ac…` is invalid for this port and is
NOT used; `UniswapV2Library.INIT_CODE_PAIR_HASH` carries the local hash
and `UniV2.t.sol::test_PairForMatchesFactory` asserts it equals
`factory.getPair()` so a stale constant fails the suite instead of
silently misrouting swaps.

The previous rehearsal set (SimplePair at nonce 13, 2026-10-02 via
`cgt_redeploy_v2.py`, pairs `0x85C5…E248`/`0xfbAb…72dd`, no router, no
TWAP) is superseded — SimplePair.sol remains in-tree as the rehearsal
reference but is no longer deployed or wired.

Note: contracts are nonce-derived (deployer `0x7099…79c8`, base nonce
41: bridge=b+0, WOMNI=b+2, rRUB=b+3, USDT=b+4, burner=b+5, factory=b+6,
router=b+7, treasury=b+10, splitter=b+11; createPair calls at b+8/b+9,
liquidity+config at b+12..b+20). Pair addresses are NOT nonce-derived —
they are CREATE2 pairs resolved via `factory.getPair()`. Nonce 0 was
consumed by an unrelated test tx before the app deploy, so the
canonical nonce-0 bridge address `0x8464…318bC` is unreachable on this
chain incarnation — the paired `OMNIL1Bridge` was redeployed to
`0x85C5Dd61585773423e378146D4bEC6f8D149E248` (L1 nonce 19) pointing at
the real L2 bridge. On a fully clean redeploy where the deployer nonce
is 0 on BOTH chains, the canonical addresses reproduce — never send
test txs from the deployer key before the app-layer deploy. Both pools
seeded 500 WOMNI / 500 quote via direct transfer+mint (equal-value
seeding; router `addLiquidity` also usable). The bridge is authorized
via `LiquidityController.authorizeMinter`. Older app-layer addresses
from previous incarnations (`0x8464…` bridge, `0x948B…`/`0x3814…`
WOMNI, `0xC6bA…`/`0x1275…`/`0x85C5…`/`0xfbAb…` SimplePair pools,
`0x0D4f…` burner, `0xAfe1…` treasury) are dead — ignore them. Anvil
runs with `--state-interval 30` so hard kills lose at most ~30 s of L1
history; app-layer txs are submitted to the EL txpool (not mined
directly) so they re-mine deterministically after any reorg/catch-up
window.

**Verified end-to-end**

- 100 OMNI `OMNIL1Bridge.depositTo` → locked on L1, `TransactionDeposited`
  in portal → L2 `LiquidityController.mint` → **100 native OMNI** to deployer
- L2 txs pay gas in OMNI; vault balances accumulate (BaseFeeVault `0x…0019`,
  SequencerFeeVault `0x…0011`, L1FeeVault `0x…001A`, OperatorFeeVault `0x…001B`)
- CGT protocol blocks verified: L1 deposit with `msg.value` → revert
  `NotAllowedOnCGTMode`; `initiateWithdrawal{value}` → revert `NotAllowedOnCGTMode`
- 50 OMNI `OMNIL2Bridge.withdrawTo` → `LiquidityBurned` (native → reserve),
  zero-value L2→L1 message **proven AND finalized** on L1:
  `WithdrawalProven` + `WithdrawalFinalized(success=true)` after
  `evm_increaseTime(910000)` (7d proof maturity + 3.5d game finality);
  deployer balance on L1 went 999,999,900 → 999,999,950 OMNI, bridge lock
  100 → 50. Full round-trip verified: tx `0x8c6f03c4…e63ec3f63c57`.
- Vault policy: `minWithdrawal=10 OMNI`, `withdrawalNetwork=L2`,
  `withdraw()` → `OMNIBurner` → `sweep()` → `0x…dEaD` — rehearsed;
  `totalBurned` accrues
- Buyback loop: pool seeded **4,000 WOMNI + 40,000 rRUB** (10 rRUB/OMNI);
  `swap 1000 rRUB → 97.27 WOMNI → unwrap → 90 OMNI → burn` verified
- Fee measurement: simple transfer ≈ **0.0015 OMNI** total fee
  (21k gas, effectiveGasPrice ~0.07 gwei, L1 fee ~95 wei on empty chain)
- op-batcher + proposer running; blob DA via beacon shim; dispute games
  (SUPER type 5) created/resolved on the CGT chain
- Kona prestate rebuilt with chain 420902 in the custom registry
  (`rust/kona/.../custom-configs/omnicor/configs.json` + `chainList.json`):
  cannon `0x031bb9b7191e2c5ef146a8417ffa7f63d8db0e238d1d3530a7d1ff17c122f82a`,
  interop `0x03d863fcfd1c81d13360c45ddabbb6fb347e0eb8fd29c0e942e887e3208aa504`
  (embeds both 420901 and 420902; artifacts in
  `rust/kona/prestate-artifacts-cannon{,-interop}/`)
- **CANNON_KONA (type 8) registered on the CGT DisputeGameFactory**
  `0xe4a64aee…63bc3`: impl `0x152f5bF1423c738AFF0afb036d950E30B09CbB53`,
  `gameArgs(8)` = prestate `0x031bb9b7…` + MIPS `0xaCc005DC…25cfA` +
  ASR `0x64bddee3…d0dc` + WETH `0xcfcb44a7…e524` + chainId `0x66c26`.
  Respected type stays 5 (makeRespected=false) — switch via guardian when
  the challenger fleet is ready.
- Note: `gameImpls` is write-once — 420901's type-8 impl keeps its earlier
  prestate `0x03dede0d` (both prestates embed 420901, so it remains valid).

## Recovery runbook — stale FCU head / op-node fork pinning

Symptoms: op-node reports unsafe/safe at an old height (e.g. 80548) with a
hash the EL does not have; log loops `failed to retrieve L2 parent block:
... could not get payload: not found` and `Sequencer backing off`. The EL
canonical tip is much higher and correct. Cause: EL forkchoice head (and/or
the node's remembered unsafe head) points at a *fork* block that was
executed during a divergence window but is not on the canonical chain.

Diagnose:

1. `optimism_syncStatus` on the node → remembered unsafe/safe hashes.
2. `eth_getBlockByNumber(<same height>)` on the EL → canonical hash. If it
   differs from the node's, the node is pinned to a dead fork.
3. `eth_getBlockByNumber("latest")` → EL canonical tip.

Fix (rehearsed on 420902):

1. Repoint the EL forkchoice head to the canonical tip, and safe/finalized
   to a canonical block at/below the last known-good height:
   `python .devnet-tools/engine_fcu.py <authRPC_port> <tip_hash> <safe_hash> <finalized_hash>`
   (JWT from `.deployer/anvil/jwtsecret.txt`; falls back V3→V2→V1).
   Expect `payloadStatus.status = VALID`.
2. Restart the op-node. On boot it adopts the EL forkchoice heads, resets
   the inconsistent unsafe tail to the last derived-consistent point and
   re-derives. The sequencer resumes on the canonical chain; "stale
   block-building job" warnings during catch-up are normal and stop when
   derivation reaches the tip.
3. Verify: `optimism_syncStatus` unsafe=safe advancing; block hash at a
   common height matches the EL.

Alternative for `admin_postUnsafePayload` (op-conductor failover API):
`.devnet-tools/block2payload` converts `eth_getBlockByNumber` output into an
envelope. Post-Isthmus blocks must carry `withdrawalsRoot` (from the block
header), not a `withdrawals` list — op-node's `CheckBlockHash` sets
`RequestsHash=EmptyRequestsHash` itself when `withdrawalsRoot` is present,
otherwise the recomputed hash never matches.

Note: transactions that lived only in dropped fork blocks are lost; if they
were never in a submitted L1 batch they must be re-initiated (e.g. a
withdrawal initiated at a fork height needs `withdrawTo` re-sent).

## Recovery runbook — L1 rewind storms (anvil restart without saved state)

Symptoms: after the L1 (anvil) dies and restarts from `--state`, the L1
timeline rewinds. op-node logs `possible L1 re-org`, walks back its L1
cursor, and then replays the entire batch backlog derived from L1. During
this replay:

- All pool transactions are ignored (`NoTxPool` — `sequencer.go:754`: when
  `attrs.Timestamp > l1Origin.Time + MaxSequencerDrift`, or while
  `Detected new block-building from L1 derivation, avoiding sequencing`).
  Txs sit in `txpool_status.pending` indefinitely — do NOT resend, they
  will mine once derivation catches up to the current L1 head.
- Pool txs that mined on dropped unsafe forks are replayed into new
  sequencer blocks only while the sequencer is in control; during the
  derivation replay, blocks contain exactly the txs from L1 batches.
- A rolling "L2 reorg: transaction count does not match" loop is normal
  while old batches replay — it stops when the derived chain reaches the
  batcher's submitted tail.

Mitigations applied:

- anvil runs with `--state-interval 30` (periodic dumps) — a hard kill
  now loses at most ~30 s of L1 blocks instead of hours.
- Docker/infra restarts must be done cleanly; every L1 rewind forces a
  full L2 derivation replay of the intervening batch data.

Operational rule: never treat a tx as final while `unsafe != safe` on a
replaying node — pool txs can be silently re-orged out until they are
inside a batch submitted to L1 and re-derived.

## WSL-native runtime + 3-node HA (2026-10-01, chain 420901)

### Architecture

Docker Desktop removed from the runtime path (memory pressure). Execution
clients run natively in WSL Ubuntu on ext4 datadirs:

- `.devnet-tools/run-l2-el.sh <name> <http> <authrpc> [ws] [p2p]` —
  op-reth with `--datadir /var/lib/omnicor-el/l2-<name>`,
  `--rollup.disable-tx-pool-gossip`, enlarged txpool, `--rpc.txfeecap 0`,
  per-instance `--ipcpath /tmp/reth-<name>.ipc` (required — the default
  `/tmp/reth.ipc` collides between instances) and `--disable-discovery`.
- EL A/B/C: http 8645/8745/8945, authrpc 8651/8751/8951.
- op-node A/B/C: rpc 9647/9747/9947, p2p 9003/9004/9006. Node C peers with
  BOTH A and B via comma-separated `--p2p.static` multiaddrs
  (requires `MSYS_NO_PATHCONV=1` under Git Bash or `/ip4/...` is mangled).
- op-conductor 1/2/3: rpc 7545/7645/7945, raft 50050/50051/50053.
- CGT chain 420902: EL 8845/8851, op-node 9847, conductor 7745 (raft 50052).

### Conductor HA — verified failover

**A 2-node raft cluster provides NO failover** — losing either member
loses quorum (needs 2/2). Three conductors are required; the cluster
membership must be built explicitly:

1. cond1 starts with `--raft.bootstrap` → 1-node cluster {cond1}.
2. `conductor_commitUnsafePayload` with the current head payload
   (`.devnet-tools/block2payload` envelope) — the FSM needs a valid
   unsafe head before any sequencer start.
3. `conductor_addServerAsVoter ["cond2","127.0.0.1:50051",0]`, same for
   cond3 → quorum of 3 (survives one failure).

Failover test result: killing the leader → new leader elected in <5 s →
sequencing resumed automatically on the follower's node; remaining
members keep quorum. Rejoining conductor re-syncs via raft replication.

**Raft FSM is monotonic** (`consensus/raft_fsm.go`): it ignores committed
payloads with a LOWER block number. If the chain is redeployed while
raft storage persists, the stale high-water mark (`consensus_num` from
the old chain) can never be overtaken and every conductor refuses to
sequence (`unsafe head mismatch` loop). **Wipe `raft*/` dirs on every
chain redeploy/genesis reset.**

`conductor_paused=true` silently blocks the control loop — resume with
`conductor_resume` (state survives only in-process, but can latch after
unhealthy-leader transitions).

### Health-check bootstrap on fresh chains

Fresh genesis is "stale" by wall clock — the default
`--healthcheck.unsafe-interval`/`safe-interval` (600 s/300 s) fail and
block sequencer start. Devnet launchers use 7200 s for both;
`--healthcheck.min-peer-count` must be >= 1 (0 is rejected) and the CL
peers must actually be connected for the check to pass.

### Batcher vs op-reth

op-reth does not implement `miner_setMaxDASize` — without
`--throttle.unsafe-da-bytes-lower-threshold=0` the batcher exits with
"Method not found". Set in both `start-stack.ps1` and the CGT
launcher.

Batcher key must match the `batcher` role in SystemConfig exactly —
a one-character typo in the private key made submissions land from an
unauthorized address (chain stalls at safe=0 with no error). Verify:
`cast wallet address --private-key <key>` vs `SystemConfig.batcherHash()`.

### Beacon shim (local blob DA)

`.devnet-tools/beacon-shim` indexes anvil blob txs by slot
(`(blockTs-genesis)/2`). Two fixes added:

- **index-on-demand**: a blob request that misses now synchronously
  catches the index up before answering. A transient 404 used to
  trigger a full derivation-pipeline reset upstream
  (`derivation failed: reset: failed to fetch blobs`), rewinding the
  safe head to genesis.
- **backfill(slot)**: binary-searches L1 blocks by timestamp to locate
  and index the block(s) covering a pruned slot — required when a node
  re-derives history older than the ~3600-slot retention window.
- Pruning: keeps the newest ~3600 slots; slot-index rebuilds from L1
  state after every L1 rollback.

Blob data itself lives in the L1 blob txs; the shim only loses its
in-memory index, never chain data.

### evm_increaseTime breaks tx inclusion (devnet time warps)

`evm_increaseTime(+604800)` (used to fast-forward the 7-day
`proofMaturityDelaySeconds` for withdrawal finalization) jumps L1
timestamps a week ahead. Consequences:

- The sequencer's L1 origin (old timestamp) drifts > Fjord
  `maxSequencerDrift` (1800 s constant, `op-node/rollup/chain_spec.go`)
  → `NoTxPool=true` → **every subsequent L2 block is empty** forever:
  the next L1 origins carry post-jump timestamps the L2 clock can never
  reach, so the origin ratchets only ~1 s per adopted block while the
  gap is tens of thousands.
- Devnet workaround applied: `maxSequencerDriftFjord` patched to
  700000 in our build + `max_sequencer_drift=1000000` in
  `rollup{,-cgt}.json` (config only applies pre-Fjord; post-Fjord uses
  the constant — both kept aligned). **Production must keep upstream
  1800** — the patch is a devnet-only accommodation for time warps.
- Preferred alternatives: deploy devnet-grade dispute timers
  (`proofMaturityDelaySeconds=120`) instead of warping L1, or snapshot
  L1 (`evm_snapshot`) before warping so `evm_revert` can undo it.

### Performance (measured 2026-10-01)

- Steady state: unsafe=safe=finalized all at 1 blk/s (block_time=1 s),
  L1 anvil at 0.5 blk/s.
- Tx throughput (spam: 40 senders × 75 txs on EL B): **1033 tx/s
  submission, 640 tx/s sustained mined, 13.5 Mgas/s**; full blocks pack
  ~1500 txs (~31.5 Mgas/block).
- Memory (8 GB host): op-node ×4 ≈ 526 MB, op-conductor ×3 ≈ 89 MB,
  batcher ×2 ≈ 38 MB, anvil 130 MB, beacon-shim 23 MB, op-reth ×3
  (WSL) ~350 MB each, `vmmemWSL` ~300 MB — total far below the
  Docker-Desktop stack that previously froze the workstation.

### Tx routing under conductor failover

`--rollup.disable-tx-pool-gossip` means txs sent to a non-sequencing EL
sit in its local pool and are never mined. Ingress (wallets/apps) must
target the CURRENT leader's EL — production needs a VIP/proxy that
follows conductor leadership; devnet: send to whichever EL's node is
sequencing (`conductor_leader`).

### Batcher follows the leader

The batcher builds channels from the unsafe head reported by ONE
op-node (`--rollup-rpc`/`--l2-eth-rpc`). If that node falls behind the
sequencing node (restart, p2p gap), `safe` stalls even though
`unsafe` keeps growing — observed 2026-10-01: node A lagged 3.3k
blocks after a restart, batcher on A froze safe at 7910 while the
leader was at 11226. Fix: point the batcher at the leader's node; on
failover repoint or use a leader-aware proxy (same VIP as tx ingress).

### P2P static peers rotate with key files

`--p2p.priv.path` keys regenerate when the file is deleted → peerIDs
change → all `--p2p.static` multiaddrs referencing the old IDs go
dial-deaf (affected nodes only derive `safe`, never see `unsafe`
gossip). After wiping `p2p/*.key`, refresh the `PEER_*` constants in
`start-stack.ps1` from `opp2p_self`.

### Kona type-8 (CANNON_KONA) challenger — validated 2026-10-01

End-to-end on anvil: deployed `FaultDisputeGame` impl
(`0x0D4ff719551E23185Aeb16FFbF2ABEbB90635942`, maxGameDepth=30,
splitDepth=14, clockExtension=10800, maxClockDuration=302400 —
`MAX_CLOCK_DURATION` must exceed `2*clockExtension` and
`clockExtension + PreimageOracle.challengePeriod(86400)` or game
creation reverts `InvalidClockExtension`), registered via
`DGF.setImplementation(8, impl, gameArgs)` where `gameArgs` is the
124-byte `PackPermissionless` layout (prestate `0x031bb9b7191e…82a`,
MIPS `0xaCc005DC…5cfa`, ASR, WETH, chainID 420902).

`create(8, forgedRoot, extraData=l2Block)` produced game
`0x0a85316297183A6FEC92137FDd5530c1Bcc0e199`; the challenger
(cannon-kona + kona-host + rebuilt `cannon-linux` with embedded
`multicannon/embeds/cannon-8`) validated the prestate, computed the
honest trace and published `attack()` tx
`0x9163927f7e25567a2adf68132986ce9e90cda3e6b22c803d7fe6b92f374cdffe`
with counter-claim `0x4231dd…ef58` — the REAL output root at the
disputed L2 block, i.e. the forged claim was correctly disputed.

**Architectural finding — FDG vs super-game anchors:**
`AnchorStateRegistry.anchors()` is now a single global root (per-type
anchors are deprecated). On a super-game deployment the anchor's
`l2SequenceNumber` is a TIMESTAMP (~1.79e9), so
`FaultDisputeGame.initialize()` can never satisfy
`l2BlockNumber > anchor.rootBlockNumber` for real blocks (~9k):
non-super FDG types (incl. cannon-kona type 8) cannot be created on
that DGF/ASR pair. The test game therefore lives on the 420901 DGF
(`0xb8d3…828c`) whose ASR was still at the block-0 `0xdead` starting
anchor, with gameArgs pointing at a mock ASR returning a REAL
(root,block) anchor — the challenger requires
`anchorStateRegistry.getAnchorRoot()` to match its own computed
output root at that block. For production: deploy a dedicated ASR
seeded with a real (root, l2BlockNumber) anchor for FDG game types,
or enable FDG only on non-super chains.

`cannon-bin` caveat: the multicannon `cannon` binary must be built
with `embeds/cannon-8` (=`bin/cannon64-impl`) inside or the
challenger's state conversion fails with
`open embeds/cannon-8: file does not exist`. Build recipe:
`cd cannon && GOOS=linux go build -o bin/cannon64-impl . &&
cp bin/cannon64-impl multicannon/embeds/cannon-8 &&
GOOS=linux go build -o bin/cannon ./multicannon/`.

## Notes

- Devnet is in-memory — redeploy loses state; re-run `docker rm -f
  omnicor-devnet` + the op-up command in roadmap/runbook to rebuild.
- Production path: `op-deployer apply` with `omnicor/intent.toml`
  (chain ID there is a placeholder — pick a globally unique one).
