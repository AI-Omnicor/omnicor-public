# OMNICOR Tokenomics — Spec

## Supply

- Total supply: **1,000,000,000 OMNICOR** (fixed, no mint after TGE).
- **OMNI is the native gas token** of the OMNICOR L2 (Custom Gas Token v2,
  enabled at genesis — cannot be retrofitted to a running chain).
- Canonical ERC-20 exists on L1; L1→L2 deposits lock ERC-20 in
  `OMNIL1Bridge` and release native OMNI from `NativeAssetLiquidity`
  via `LiquidityController` (genesis reserve = full 1B supply).
- Supply invariant (exact form):
  `L1 bridge locked == L2 native outside NativeAssetLiquidity
   + in-flight deposits + in-flight withdrawals`.
  The naive `bridge == circulating` form breaks while a deposit is locked
  but not yet released, or while a withdrawal is burned into
  NativeAssetLiquidity but not yet finalized on L1. Native OMNI sent to
  `0x…dEaD` stays inside "L2 native" — it counts as permanently locked
  backing, which is why burning reduces effective circulating supply
  without ever releasing L1 collateral.

## Gas fees and burn policy (CGT)

- Every L2 transaction pays OMNI gas → fees accumulate in
  BaseFee/SequencerFee/L1Fee/OperatorFee vaults (withdrawalNetwork = L2 —
  value withdrawals to L1 are protocol-blocked in CGT mode).
- Policy (fixed): vault `withdraw()` → `FeeSplitter` → `sweep()` →
  **70% burned** via `OMNIBurner` → `0x…dEaD`, **30% to OMNICORTreasury**.
  The 70/30 ratio is a hardcoded contract constant — nobody can change it.
  `minWithdrawalAmount ~10 OMNI`, permissionless `withdraw()`/`sweep()`.
  Net effect: sustained network usage is deflationary to circulating supply.
- **Rehearsal state (honest note):** only `BaseFeeVault` is routed to
  `OMNIBurner` today; the other three vaults still point at a devnet
  address, and accumulation is not burning — supply shrinks only after
  `withdraw()` + `sweep()`. Before production, set all four vault
  recipients (`setWithdrawalRoute` by the L2 ProxyAdmin owner) to the
  deployed `FeeSplitter` and verify each vault's route on-chain.
- Buyback-and-burn (external revenue): fiat → stable → `SimplePair` swap →
  WOMNI → unwrap → `OMNIBurner` → dead. Verified on rehearsal (chain 420902).
- Revenue-linked reserve burn (debt-ledger path, no foreign entity
  needed): the platform books a buyback obligation for EVERY ride —
  both RU and INTL contours — and FIXES its OMNI amount in the ledger
  at the OMNI rate on the day the debt is recorded (decided policy —
  no settlement-day repricing). The ledger is currency-agnostic: each
  record stores the original fare currency + amount for accounting,
  but the obligation itself is denominated in OMNI from the moment of
  record. INTL rides convert fare→OMNI at record time via an agreed
  rate source (e.g. local→USDT→OMNI).
  Periodically the Safe burns exactly the accumulated OMNI sum —
  `OMNICORToken.transfer(0x…dEaD, amount)` on L1, prepared by
  `.devnet-tools/revenue_burn.py --omni` or `--ledger-file <export.json>`
  (re-sums the platform's export and refuses on omni_total mismatch).
  Settlement is verifiable trustlessly: `revenue_burn.py --verify
  <tx>` checks the receipt's `Transfer→0x…dEaD` log and the exact wei
  amount on-chain — the ledger's `settlement_tx` id is provable, not
  trusted. The reserve shrinks and the supply burns against real
  revenue; no market purchase or foreign legal entity is required.
  Optional `--burn-bps` applies the 70/30 policy if only part of the
  earmark should burn; `--rub`/`--price` remains as a manual
  conversion mode.
- Measured fee: simple transfer ≈ **0.0000015 OMNI** at near-zero load
  (21,000 gas × ~0.07 gwei baseFee ≈ 1.47×10⁻⁶ OMNI; 1s blocks, 60M gas
  limit). Contract writes cost proportionally more gas.

## Allocations (platform-agreed with taksi-platform)

| Bucket | Share | Rule |
|---|---|---|
| Initial market issue | **10%** | released at launch |
| Developer (founder) | **20%** | 6-month cliff, then linear vesting over 4 years (`DevVesting.sol`) |
| Reserve | **70%** | locked in `ReserveVesting.sol`, released over **40 quarters on a decreasing schedule**: quarter i carries weight `41 - i` (40, 39, …, 1; total weight 820), so quarter 1 unlocks ≈4.878% of the allocation (~34.1M OMNI) and each next quarter is strictly smaller; each tranche releases as a lump at quarter start |

The earlier draft splits (35/25/20 etc.) are superseded by this table.

## Dev vesting mechanics (`DevVesting.sol`)

- `cliffEnd` = deploy time + **182 days**. Before it — zero movement.
- After `cliffEnd`: tokens vest **linearly over `DURATION` = 4 years** from
  deploy. At the cliff ~12.5% (25M OMNI) unlocks at once; afterwards about
  **4.17M OMNI per month** becomes withdrawable, second by second — the
  beneficiary can withdraw at any moment. The vesting curve itself is the
  rate limit: unvested tokens cannot leave the contract.
- The cap is implemented on-chain in the contract itself — the beneficiary's
  MetaMask only ever sees `transferable()` tokens at a time. Rate-limiting
  ordinary ERC-20 transfers from an EOA is impossible, so the cap must live in
  the vesting contract, not in the wallet.
- Dev wallet address is set once at deploy and is **immutable** — no admin
  function can reroute the allocation elsewhere. Owner functions are limited
  to none — the contract is non-custodial, non-upgradeable.
- Production beneficiary (founder MetaMask): `0x499DE52ED1d855fb1c4f7a7a90283d8b9D385a77`.
  The address is chain-agnostic — it is valid on the OMNICOR L2 and on any
  EVM network, including the future L1 deployment.

## Honest notes

- Approved schedule (2026-09-27): **182-day cliff + 4-year linear vesting**.
  Founder opted against the original 5-year hard cliff + 10%/mo cap so the
  allocation starts earning after ~6 months instead of 5 years.
- Once tokens are in the dev wallet they are free ERC-20 — nothing can cap
  their resale (that is a market/AMM problem, not a contract one).
- Before any real deploy: external audit, plus a testnet rehearsal with an
  accelerated clock.

## Reserve vesting mechanics (`ReserveVesting.sol`)

- The 70% reserve vests to the **governance/treasury key**, not the
  founder's personal wallet — beneficiary separation is mandatory:
  dev pool → founder MetaMask, reserve pool → treasury (multisig in
  production). Vesting beneficiaries are immutable at deploy, so this
  must be set correctly the first time.
- `start` = deploy time, `end` = start + 40 × 90 days (~9.86 years).
- Tranche i = `allocation × (41 − i) / 820` — arithmetic decay,
  strictly decreasing, sums to exactly the allocation; each tranche
  releases as a lump at the start of its quarter.
- **Burn-on-expiry (platform policy):** a tranche is claimable ONLY
  during its own quarter. Whatever is not claimed by quarter end is
  burned forever — `burnExpired()` (permissionless) sends the unclaimed
  remainder to `0x…dEaD`. Unsold/unclaimed supply is destroyed, not
  carried over: only what the Safe deliberately takes ever enters
  circulation. `burned` counter + `Burned(period, amount)` events keep
  the accounting on-chain.
- Beneficiary is immutable at deploy; `withdraw`/`withdrawAll` are
  **permissionless** — anyone may trigger the release but tokens can only
  ever go to the beneficiary. This lets a keeper bot
  (`.devnet-tools/vesting_keeper.py`) claim tranches and settle expiries
  on schedule without any human signature; spending them out of the
  beneficiary still requires the Safe's 2-of-3. No owner, no upgrade
  path — the reserve cannot be rerouted or accelerated.
- **Operational note:** the keeper must be reliable — if it is down for
  an entire quarter, that quarter's tranche burns unclaimed by design.
- **Quarterly market-release procedure (intended flow):**
  1. Quarter opens → the tranche sits IN the vesting contract, not in
     the Safe. The Safe pulls out only what it actually places on the
     market (2-of-3, as sales need it).
  2. It trades for the quarter.
  3. Whatever was never pulled out burns automatically — no return
     trip from the exchange, no burn transaction needed. A new tranche
     can only be claimed AFTER the previous quarter's leftover is
     burned: the burn happens inline inside the next `withdraw`/
     `withdrawAll` call (or permissionless `burnExpired()`).
  4. Next quarter releases a strictly smaller tranche; repeat.
  Net effect: every token either sells or burns — none can idle, and
  the burn is enforced by the contract, not by procedure.
- **CEX remainder automation (post-listing):** tokens inside a
  centralized exchange are exchange-custodied — no contract can burn
  them remotely. `.devnet-tools/cex_burn_bot.py` automates it: holds
  only withdrawal-scoped API keys, withdraws the unsold balance
  straight to `0x…dEaD` (constant, not a parameter — it cannot send
  anywhere else), verifies settlement. Keys must be restricted to the
  dead address in the exchange's whitelist. Until API access exists,
  the remainder settles manually: withdraw + dead-address send, one
  Safe action per quarter.
- Verified by tests: strict decrease, sum≈70% (wei-level dust only),
  quarter boundaries, claim-window enforcement, expiry burn.

## Treasury (`Treasury.sol`, on-chain name "OMNICOR Treasury")

- Holds native OMNI (payable reserve) — tops up hot executor wallets per
  legal contour: `topUpExecutor(RU|INTL, amount)`; consolidates to cold
  corporate addresses via `sweepToCold`. Cold addresses are stored
  on-chain as data only — keys never live on the server.
- Owner (multisig in prod) configures executor/cold addresses via
  `setExecutor` / `setColdWallet`.
