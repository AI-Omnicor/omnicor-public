# OMNICOR — production address registry

Canonical production addresses derived from the **privately generated**
production seed (generated offline by the founder on 2026-10-03; the seed
itself is never committed anywhere — only these public addresses are).

| # | Role | Address | Contract binding |
|---|------|---------|------------------|
| 1 | OMNICOR Treasury (Safe) | `0x2F4d03593eCbA5F1B0c8491275454eCA3202AB96` | ReserveVesting beneficiary (70%), Treasury owner, ProxyAdmin owner |
| 2 | Pool Management | `0x550535CDAd8F3B0a5d45E81Acacd390103845809` | Deployer EOA (L1 app layer) + holder of the 10% circulating allocation (100M OMNI); Safe signer #2 |
| 3 | Founder Beneficiary | `0x499DE52ED1d855fb1c4f7a7a90283d8b9D385a77` | DevVesting beneficiary (20%); Safe signer #1 |

## Treasury Safe (multisig 2-of-3) — deployed on Ethereum mainnet

**Safe address: `0x2F4d03593eCbA5F1B0c8491275454eCA3202AB96`** (name
"OMNICOR", deployed via `app.safe.global` on Ethereum mainnet on
2026-10-03; EIP-55 checksum verified, deployment activated and showing
2-of-3 on the Safe dashboard — still verify the contract on Etherscan
before wiring into deploy config).

Three independent signers (three different seed phrases, different
devices):

| Signer | Key location | Address |
|--------|--------------|---------|
| #1 | Founder MetaMask (PC+phone installs) | `0x499DE52ED1d855fb1c4f7a7a90283d8b9D385a77` |
| #2 | Production seed EOA | `0x550535CDAd8F3B0a5d45E81Acacd390103845809` |
| #3 | Phantom (Ethereum account) | `0xe5400d849daff15639704654c152f9e1c36ae517` |

**Threshold: 2 of 3.** The Safe address `0x2F4d…AB96` is the
ReserveVesting beneficiary (70%), Treasury contract owner and
ProxyAdmin owner. The vesting beneficiary is immutable — the Safe
address is what gets baked into the L1 deploy.

## Hard rules

- **Vesting beneficiaries are immutable.** DevVesting→founder and
  ReserveVesting→treasury are baked at deploy time; there is no reroute.
  If the treasury must end up behind a Safe multisig, deploy the Safe
  *first* and register ITS address as the ReserveVesting beneficiary —
  upgrading an EOA treasury to a Safe after deploy is impossible.
- **Deployer must stay at nonce 0** on the target L1 until the app-layer
  deploy runs. All canonical addresses (token, vestings, L1 bridge) are
  nonce-derived; any prior transaction from `0x5505…` shifts every
  address and invalidates the paired-bridge wiring on L2.
- Address #2 funds pools/liquidity from its 10% — it is a hot ops
  wallet by design; keep its operational balance minimal beyond that.
- Addresses are public; nothing secret belongs in this file.

## Infra roles (L2 layer) — ops seed, allocated 2026-10-04

Dedicated operations seed (24 words), generated offline on this machine
on 2026-10-04 — never entered the agent transcript. Backup: **paper
only** — the mnemonic and private-key files were deleted after
transcription; keys re-derive from the seed at deploy time. Standard
`m/44'/60'/0'/0/<index>` derivation. These are HOT keys living on the
server — bounded gas balances only, never treasury funds, never Safe
signers.

| Role | Address | Index |
|------|---------|-------|
| Sequencer signer (unsafeBlockSigner) | `0x9809F64bE9feD7dF3fB49b791671c4C57a4AfDd1` | 0 |
| Batcher | `0x87B3E2155F704B5b09ffDf58c5b6689F0169ACf0` | 1 |
| Proposer | `0xf579FE55211C4FE4C1AF0f80A7eBDCBf6bf0103f` | 2 |
| Challenger | `0x65F29026FF6466De7768eA165BF7511401dd13dE` | 3 |
| Vesting keeper | derived at deploy (ops index 4) — gas-paying key only for `.devnet-tools/vesting_keeper.py`; triggers permissionless releases, holds nothing | 4 |

L2 ProxyAdmin owner → treasury Safe (governance role, not a hot key).
