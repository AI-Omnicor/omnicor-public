# OMNICOR — production deployment checklist

Run order for taking OMNICOR from rehearsal devnet to a live OP Stack
chain on Ethereum mainnet. Every step lists its gate — do not proceed
past a failed gate.

## Phase 0 — keys and treasury (DONE)

- [x] Production seed generated privately by the founder (never enters
      any repo, chat, or agent session)
- [x] Treasury Safe deployed on Ethereum mainnet:
      `0x2F4d03593eCbA5F1B0c8491275454eCA3202AB96` — 2-of-3
      (founder MetaMask `0x499D…`, prod seed `0x5505…`, Phantom `0xe540…`)
- [x] Registry updated: `omnicor/production-addresses.md`
- [ ] **Verify on Etherscan**: Safe proxy exists at the address above,
      `getOwners()` returns the three signers, `getThreshold()` = 2
- [ ] Cold-backup check: all three seed phrases on paper, in separate
      physical locations. Phantom seed confirmed written down.
- [ ] Consider a dedicated hardware signer for the Safe before large
      balances accumulate (swap a signer via the Safe — owners are
      mutable, unlike contract immutables)

## Phase 1 — deployer preparation

- [ ] Fund deployer `0x550535CDAd8F3B0a5d45E81Acacd390103845809` on
      Ethereum mainnet with deployment gas (est. 0.05–0.15 ETH depending
      on gas price; fund ~0.2 ETH to be safe)
- [ ] **Confirm deployer nonce = 0** on mainnet:
      `cast nonce 0x5505… --rpc-url $MAINNET_RPC` must print `0`.
      Any prior transaction shifts every derived address.
- [ ] Decide whether the same key deploys the L2 app layer (predicted
      L2 bridge = deployer nonce-0 on L2). If yes, keep its L2 nonce 0
      until the L2 deploy.
- [x] Allocate and document infra-role keys: dedicated ops seed
      (24 words, generated offline 2026-10-04, never in transcript) →
      sequencer `0x9809…fDd1` (idx 0), batcher `0x87B3…ACf0` (idx 1),
      proposer `0xf579…103f` (idx 2), challenger `0x65F2…d3dE` (idx 3).
      Public addresses in `production-addresses.md`; seed + keys in
      `E:\Omnicore\ops-keys\` pending paper transcription + encryption.

## Phase 2 — L1 protocol layer (op-deployer)

- [x] Prepare the intent config for mainnet — `omnicor/intent.toml`
      filled: chain ID 420903 (verified unregistered 2026-10-04,
      claim via ethereum-lists PR before launch), `l1ChainID = 1`,
      roles + vaults + liquidity owner → Safe / ops keys.
      Remaining blocker by design: `opcmAddress` until Phase-2 OPCM
      bootstrap; preflight fails closed on exactly that.
- [ ] Confirm fault-proof parameters in the intent are **permissionless**
      game type (not respectedGameType=5 permissioned)
- [ ] Run `op-deployer apply` against mainnet; capture the L1 contract
      artifacts (state JSON)
- [ ] Record from artifacts: `L1CrossDomainMessengerProxy` address
      (→ `OMNI_L1XDM`), `L1StandardBridgeProxy`, `SystemConfig`,
      `OptimismPortal2`, `DisputeGameFactory`, `ProxyAdmin` owner
- [ ] Transfer ProxyAdmin ownership to the treasury Safe
      `0x2F4d…AB96` — verify `owner()` on-chain after the transfer
- [ ] Configure SystemConfig roles: batcher hash, proposer, unsafe
      block signer — use the infra keys from Phase 1, NOT treasury keys

## Phase 3 — L1 OMNI app layer

- [ ] Export env in the deploying shell (key never touches disk/repo):
      `OMNI_ENV=prod`, `OMNI_L1_RPC`, `OMNI_DEPLOYER_KEY`,
      `OMNI_L1XDM` (from Phase 2 artifacts)
- [ ] Dry review: predicted addresses — the script prints them from
      `cast compute-address`; sanity-check before broadcasting
- [ ] Run `.devnet-tools/l1_deploy_omni.py`; confirm:
      DevVesting → founder `0x499D…` (200M),
      ReserveVesting → **Safe `0x2F4d…AB96`** (700M) — immutable,
      re-verify on-chain: `cast call $RESERVE_VESTING "beneficiary()(address)"`
- [ ] Verify token supply split on-chain: 200M / 700M / 100M circulating
- [ ] `l1-deploy-prod.json` manifest produced — feed into L2 wiring
- [ ] Verify contracts on Etherscan (`forge verify-contract`)

## Phase 4 — L2 launch

- [ ] Generate genesis + rollup config from the L1 artifacts (real L1
      contract addresses, not devnet values)
- [ ] Deploy the L2 OMNI app layer (bridge counterpart); confirm the
      deployed L2 bridge matches `l2BridgePredicted` in the manifest —
      if the L2 nonce wasn't 0, redeploy the L1 bridge binding via
      `OMNI_L2_BRIDGE`
- [ ] Bring up: op-geth/op-reth (EL), op-node, op-batcher, op-proposer,
      op-challenger — point at the production rollup config
- [ ] First blocks: watch unsafe/safe head progression, batcher posting
      to L1, proposer submitting outputs

## Phase 5 — bridge e2e (mandatory before announcing)

- [ ] Deposit: L1 OMNI → L2 native gas token; confirm credit on L2
- [ ] Withdrawal: initiate on L2 → wait for output proposal → prove →
      finalize on L1 → confirm OMNI released by OMNIL1Bridge
- [ ] Dispute path: confirm challenger watches the game type actually
      configured; test a challenge on the game
- [ ] Fee vaults routing: all four vault recipients → deployed
      `FeeSplitter` (immutable 70% burn / 30% OMNICORTreasury),
      `setWithdrawalRoute` verified on-chain per vault
- [ ] Vesting keeper live: `.devnet-tools/vesting_keeper.py` running on
      the server (env `OMNI_KEEPER_KEY` = ops index 4 key with small L1
      ETH float + small L2 OMNI float, `OMNI_DEV_VESTING`,
      `OMNI_RESERVE_VESTING`, `OMNI_L1_RPC`; optional `OMNI_L2_RPC` +
      `OMNI_FEE_SPLITTER` for automatic 70/30 fee sweeps). Vesting
      releases and the splitter sweep are permissionless — the keeper
      only schedules them; tokens still land only in the Safe/founder
      and the treasury. Verify a `Withdrawn` event each quarter and
      `Split`/`Burned`/`Burned(period)` events on the explorer.
      ReserveVesting tranches expire at quarter end — the keeper must
      stay reliable or the tranche burns unclaimed.
- [ ] After listing: `cex_burn_bot.py` live with withdrawal-scoped API
      keys whitelisted to `0x…dEaD` only; verify the first quarterly
      unsold-remainder burn settles on-chain

## Phase 6 — production hardening (before public traffic)

- [ ] Replace MockQuote/SimplePair with canonical AMM components —
      they are rehearsal stubs by design
- [ ] Permissionless fault proofs live and verified (prestate hashes
      pinned, challenger bonded)
- [ ] External security audit of `omnicor/contracts` + bridge wiring +
      any OP Stack modifications — findings resolved
- [ ] HA: second op-node + EL replica, conductor failover test,
      rollup-boost/builder path tested
- [ ] Monitoring: Prometheus stack ingesting `omnicor_*` metrics from the
      LIVE endpoints; alerts wired to on-call
- [ ] Runbooks: sequencer failover, batcher/proposer outage, safe-head
      stall, withdrawal incident — rehearsed once on staging
- [ ] Load test at target TPS on production-like hardware

## Phase 7 — launch ops

- [ ] Public RPC endpoint(s) behind LB + rate limits
- [ ] Explorer deployed and indexed from genesis
- [ ] Token listing metadata: `omnicor/brand` package (logos verified)
- [ ] Announce only after Phase 5 fully passes
