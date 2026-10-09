# OMNICOR — External Business Integration Guide

Target integration: ride-hailing platform (83 countries, two operating
contours — Russia and international). This document defines every on-chain
surface the external backend touches: how to get native OMNI, how to write
records without exposing users to crypto, how buyback-and-burn works, and
what read APIs exist for monitoring.

Everything below is rehearsed on the local CGT rehearsal chain
(chain ID **420902**, see `deployments.md`). Sepolia rehearsal and mainnet
parameters get separate documents/updates when credentials are available.

---

## 1. Chain identity

| Parameter | Rehearsal value | Production |
|---|---|---|
| L2 chain ID | `420902` (`0x66c26`) | pick globally unique, e.g. via chainlist |
| Native currency | `OMNI` (name `OMNICOR`, 18 decimals) | same |
| L1 | anvil 31337 `localhost:9545` | Sepolia → Ethereum mainnet |
| L2 RPC (rehearsal) | `http://localhost:8845` | public RPC TBD |
| op-node RPC | `http://127.0.0.1:9847` | internal |

Wallets/explorers show OMNI natively — the chain reports
`gasPayingTokenName = "OMNICOR"`, `gasPayingTokenSymbol = "OMNI"` from the
`LiquidityController` predeploy; block explorers (Blockscout) read the same.

## 2. Custom Gas Token (CGT v2) — consequences

This is **CGT v2** (OP Stack Upgrade 18 / op-contracts v6). Key facts:

- **Genesis-only.** `isCustomGasToken` is baked into both L1 `SystemConfig`
  and L2 `L1BlockCGT` at genesis. It cannot be enabled on an already-running
  chain without redeployment. → CGT must be in the intent **before** the
  final production launch. Confirmed in the rehearsal intent
  (`.deployer/anvil-cgt/intent.toml`).
- **Native asset is a reserve, not a bridge derivative.** At genesis
  `NativeAssetLiquidity` (predeploy `0x4200…0029`) holds
  `initialLiquidity` native OMNI; `LiquidityController` (`0x4200…002A`)
  releases/burns it for **authorized minters only**.
- **ETH moves are blocked by the protocol** (verified on rehearsal):
  - `OptimismPortal.depositTransaction` with `msg.value>0` →
    `OptimismPortal_NotAllowedOnCGTMode`
  - `L2ToL1MessagePasser.initiateWithdrawal` with `msg.value>0` →
    `L2ToL1MessagePasserCGT_NotAllowedOnCGTMode`
  - ERC-20 / message bridging works normally (zero-value paths only).
- **`useInterop = false`** — correct and required today. CGT chains are
  excluded from the interop cluster; cross-chain mintable OMNI via the
  interop protocol is not available. If a future OP Stack release ships CGT
  interop support, enabling it is a deliberate upgrade, not a flag flip.
- **All bridging is application-layer.** The protocol ships no token bridge
  for the gas asset — we deploy our own (below). This is by design and is
  the OP Foundation-documented model.

## 3. The OMNI bridge (application layer)

Two immutable, ownerless contracts — no admin keys, no upgrade path:

| Contract | Chain | Rehearsal address |
|---|---|---|
| `OMNICORToken` (ERC-20, 1B fixed) | L1 | `0x948B3c65b89DF0B4894ABE91E6D02FE579834F8F` |
| `OMNIL1Bridge` (locks ERC-20) | L1 | `0x85C5Dd61585773423e378146D4bEC6f8D149E248` |
| `OMNIL2Bridge` (authorized minter) | L2 | `0x2dE080e97B0caE9825375D31f5D0eD5751fDf16D` |

Sources: `omnicor/contracts/src/OMNIL1Bridge.sol`,
`omnicor/contracts/src/OMNIL2Bridge.sol`.

### Deposit (L1 → L2)

```text
user/backend:  OMNI.approve(L1Bridge, amt)
               L1Bridge.depositTo(to, amt, minGasLimit)     // ~200k is safe
               └─ locks OMNI ERC-20 in the bridge
               └─ L1CrossDomainMessenger.sendMessage → L2
auto (deposit tx): L2CrossDomainMessenger.relayMessage
               └─ OMNIL2Bridge.finalizeDeposit(to, amt)
               └─ LiquidityController.mint(to, amt)          // reserve → user
```

Rehearsed: 100 OMNI locked on L1 → 100 native OMNI appeared on L2
(`DepositFinalized` event; `LiquidityMinted` on `0x4200…002A`).

### Withdrawal (L2 → L1)

```text
user/backend:  OMNIL2Bridge.withdrawTo(to, minGasLimit){value: amt}
               └─ LiquidityController.burn{value: amt}()    // native → reserve
               └─ zero-value message → L1 (CGT requires value=0)
wait:          safe block → dispute game covers the block → resolve
finalize:      portal.proveWithdrawalTransaction(...)       // storage proof
               wait proofMaturityDelay (prod = 7d)
               portal.finalizeWithdrawalTransaction(...)
               └─ L1CrossDomainMessenger.relayMessage
               └─ OMNIL1Bridge.finalizeWithdrawal → OMNI ERC-20 released
```

Rehearsed: 50 OMNI burned on L2 (`LiquidityBurned` event on `0x4200…002A`),
message proven against a live dispute game on L1 (`WithdrawalProven` at
`0x17d3a2ca…`). Finalization is mechanically identical to the proven ETH
withdrawal flow already exercised end-to-end on chain 420901.

**Supply invariant:** `L1 bridge balance == L2 circulating native OMNI`
(reserve excludes circulating). Burning native OMNI to `0x…dEaD` therefore
permanently reduces total circulating supply — the backing ERC-20 stays
locked forever.

## 4. Fee vaults → burn policy

Vaults (all `withdrawalNetwork = L2`, permissionless `withdraw()`):

| Vault | Predeploy | Rehearsal recipient |
|---|---|---|
| BaseFeeVault | `0x4200…0019` | `OMNIBurner` `0x0D4f…5942` |
| SequencerFeeVault | `0x4200…0011` | `0x14dC…9955` (rehearsal) |
| L1FeeVault | `0x4200…001A` | `0x14dC…9955` (rehearsal) |
| OperatorFeeVault | `0x4200…001B` | `0x14dC…9955` (rehearsal) |

Policy (production, decided):

- **Recipients** — all four vaults route to `FeeSplitter`: on `sweep()`
  it burns **70%** via `OMNIBurner` → `0x…dEaD` and forwards **30%** to
  `OMNICORTreasury`. The 70/30 ratio is a hardcoded constant with no
  owner/setter — decided platform policy, not a tunable.
  `setWithdrawalRoute` is callable by the L2 ProxyAdmin owner at any
  time — not genesis-locked.
- **Frequency** — `minWithdrawalAmount` gates it; set ~1–10 OMNI so sweeps
  happen organically. Anyone can call `withdraw()`/`sweep()` — the
  vesting keeper already does it when `OMNI_L2_RPC` + `OMNI_FEE_SPLITTER`
  are set.
- **"Every transaction reduces supply"** — technically true via this route:
  every tx pays OMNI gas → vaults accumulate → `withdraw()` → Splitter →
  `sweep()` → 70% to `0x…dEaD`, 30% to treasury. Rehearsed end-to-end
  (BaseFeeVault → Burner → dead, `totalBurned` counter incremented).
- **Accounting caveat to state honestly:** vault accumulation alone does not
  reduce supply — the burn is real only after `sweep()`. Track
  `OMNIBurner.totalBurned` + `Burned` and `FeeSplitter.Split` events.

## 5. Buyback-and-burn infrastructure (taxi revenue loop)

Deployed on L2 (canonical Uniswap V2, `.devnet-tools/cgt_redeploy_v3.py`):

| Contract | Address | Purpose |
|---|---|---|
| `WOMNI` | `0xc63d2a04762529edB649d7a4cC3E57A0085e8544` | WETH9-style native wrapper for ERC-20 venues |
| `MockQuote` (rRUB) | `0x1a6a3e7Bb246158dF31d8f924B84D961669Ba4e5` | rehearsal quote asset (mintable) |
| `MockQuote` (USDT) | `0x093e8F4d8f267d2CeEc9eB889E2054710d187beD` | rehearsal quote asset (mintable) |
| `UniswapV2Factory` | `0x34ee84036C47d852901b7069aBD80171D9A489a6` | CREATE2 pair factory |
| `UniswapV2Router02` | `0xa85b028984bC54A2a3D844B070544F59dDDf89DE` | add/remove liquidity, swap paths |
| `UniswapV2Pair` WOMNI/rRUB | `0x2e79fb9360d8a45383939877bcf9ce9048f54439` | canonical AMM, 0.3% fee, TWAP |
| `UniswapV2Pair` WOMNI/USDT | `0x37c0a78e8d5a0f7487ec26a45ad5c41ac01c349c` | canonical AMM, 0.3% fee, TWAP |
| `OMNIBurner` | `0xBa3e08b4753E68952031102518379ED2fDADcA30` | dead-address burner w/ events |
| `FeeSplitter` | `0x35D2F51DBC8b401B11fA3FE04423E0f5cd9fEDb4` | immutable 70% burn / 30% treasury split |

Rehearsal pool: **500 WOMNI + 500 rRUB** (same for the USDT pair).
Rehearsed flow: `1000 rRUB → swap → 97.27 WOMNI → unwrap → 90 OMNI →
OMNIBurner → sweep → 0x…dEaD`. All verifiable: `Swap`, `Withdrawal` (WOMNI),
`Burned` events; `totalBurned()` counter.

### Production design choices

- **Pool placement: L2.** Buyback happens where OMNI circulates natively;
  no L1 round-trip per cycle; L1 pool optional later (would need ERC-20
  unwrap step for burn accounting).
- **Pair: OMNI/stablecoin.** For the Russian contour a RUB-settlement
  stablecoin; international — USDT/USDC. The canonical Uniswap V2 port
  (`src/univ2/` — Factory+Pair+Router02) is deployed on devnet and is
  the production AMM; `SimplePair` remains in-tree as historical
  rehearsal reference only and is not wired anywhere.
- **Seed liquidity**: from the 10% pool bucket —
  recommendation `50M OMNI` + equivalent stable. Price = `quote/OMNI`;
  impact for buy of size `Δ`: `price × (1 + Δ/reserve_quote)` approx.
  Keep single buybacks ≤ ~2% of the quote reserve to bound slippage
  (router-side `minOut` required anyway).
- **Burn mechanism choice: dead address, not token `burn()`.**
  Native OMNI has no token-level burn (it's the chain's gas asset, not an
  ERC-20). Sending to `0x…dEaD` is irreversible, provable via
  `eth_getBalance(0x…dEaD)` + `Burned` events, and needs no trust in a
  burner owner. Whether to also add `burn()` to `OMNICORToken.sol` (for
  L1-side burns) — open decision, see §8.

### Read API surface for the external backend

All plain JSON-RPC, no subgraph needed:

| Question | Call |
|---|---|
| Pool reserves | `eth_call pair.getReserves()` |
| Spot price quote/OMNI | derive from `getReserves()` — `token0()` tells the WOMNI slot |
| Quote for a buy | `eth_call router.getAmountsOut(amountIn, [tokenIn, womni])` — or local 997/1000 math on reserves |
| Cumulative burned via Burner | `eth_call OMNIBurner.totalBurned()` |
| Native balance at dead addr | `eth_getBalance 0x…dEaD` |
| Vault pending fees | `eth_getBalance <vault>` |
| Burn events | `eth_getLogs` topic `Burned(address,uint256,uint256)` on OMNIBurner |
| Deposit/withdrawal flow | `eth_getLogs` on bridge event signatures |

### The fiat loop (outside blockchain scope, documented for completeness)

`passenger fiat → platform settlement account → stablecoin purchase on the
settlement venue (off-chain) → stable lands in the buyback wallet →
swap on UniswapV2Pair (via Router02) → WOMNI → unwrap → OMNIBurner → dead.`
The on-chain entry point is the **quote-token transfer into the pair +
`swap()`**; everything before that is business/legal infrastructure.

## 6. Gas abstraction for external users

End users (passengers/drivers) must never touch crypto. Recommended
architecture — **backend relayer** (simplest, no user-facing keys):

- A Go sidecar service (taxi backend is Go) holds a funded **treasury
  account** key and submits signed L2 txs on behalf of the business:
  shift-paid receipts, ride-completed proofs, payout references.
- Treasury funding: deposit OMNI through `OMNIL1Bridge.depositTo(treasury, …)`
  or buy on the L2 pool. Top-up policy: alert at < threshold, refill weekly.
- Measured tx cost on rehearsal: simple transfer ≈ **1.5×10⁻⁶ OMNI**
  (21,000 gas × ~0.07 gwei baseFee, near-empty chain); contract writes
  ~50–80k gas ≈ **3.5–5.6×10⁻⁶ OMNI** per record. At 60M gas/block and 1s
  blocks the chain sustains ~2–4M records/hour — far above needs.
- ERC-4337 paymaster: viable later for user wallets, but adds
  bundler/paymaster infra the backend model doesn't need. Decision:
  **relayer first**, ERC-4337 only if self-custody wallets appear.

Two contours note: one L2 serves both; separation lives at the relayer
level (separate treasury keys / separate services per contour), not in
separate chains — single liquidity pool, single burn accounting.

## 7. Role addresses (rehearsal — replace all for production)

| Role | Rehearsal address | Production |
|---|---|---|
| Superchain PAO / Guardian / Challenger | `0xf39F…`, `0x3C44…`, `0x976E…` | multisigs |
| L1+L2 ProxyAdminOwner | `0x7099…` | multisig |
| SystemConfig owner | `0x3C44…` | multisig |
| Batcher / Proposer | `0x15d3…` / `0x9965…` | dedicated hot keys |
| LiquidityController owner | `0x7099…` (=L2PAO) | L2PAO multisig |
| Fee vault recipients | see §4 | Burner / FeeSplitter |
| Relayer treasury | — | dedicated hot wallet + daily limits |

## 8. Open decisions before production

1. `initialLiquidity` — rehearsal used **1B OMNI** (full supply as reserve).
   With 1:1 bridge backing this is the coherent choice; alternative is a
   smaller reserve + pre-minted allocations in genesis alloc. **Recommended:
   keep 1B.**
2. `liquidityControllerOwner` — rehearsal used L2PAO. Production: the same
   multisig as L2PAO is fine (it already gates L2 contract upgrades).
3. Token `burn()` on L1 ERC-20 — optional addition for L1-side buyback
   burns; not required for the L2 burn flow. If added, redeploy token.
   **No tokenomics change made — awaiting decision.**
4. Allocation review: 25% community/liquidity suffices for seed (50M) +
   relayer buffer (5M) + early holders; treasury 20% separate. Confirm.
5. ERC-4337 vs relayer — recommended relayer first (§6).
6. Fault-proof role addresses for production (multisigs); challenger key.
7. Sepolia credentials: funded deployer + RPC endpoint — then run the same
   rehearsal there.
8. Quote asset choice per contour (RUB-stable for RU, USDT/USDC for intl).
