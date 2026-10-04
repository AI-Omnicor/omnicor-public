# OMNICOR Security Policy

**Scope of this policy:** the OMNICOR layer on top of the OP Stack —
`contracts/` (OMNICORToken, DevVesting, ReserveVesting, OMNIL1Bridge,
OMNIL2Bridge, FeeSplitter, OMNIBurner, OMNICORTreasury, WOMNI, SimplePair)
and the chain services described in `docs/`.
For upstream OP Stack issues see the
[Optimism security policy](https://github.com/ethereum-optimism/.github/blob/master/SECURITY.md).

## Reporting a vulnerability

**Do not open a public issue.** Report privately:

- Email: `security@omnicor.io`
- Include: affected contract/component, impact, reproduction steps or
  proof-of-concept, suggested severity.

We acknowledge within 72 hours. Critical findings (loss of funds,
unauthorized mint/burn, bridge escape, vesting bypass) get an emergency
response path; we will coordinate disclosure timing with the reporter.

## Security model — what protects funds

| Surface | Control |
|---|---|
| Treasury spends | Safe 2-of-3 multisig; contract owner is the Safe, not an EOA |
| Fee destinations | `FeeSplitter` burner/treasury are immutable; ratio is a constant |
| Bridges | Immutable, no admin keys, no upgrade path; withdrawals fault-proven |
| Vesting contracts | Permissionless claims — funds can only reach the immutable beneficiary |
| Keepers/bots | Gas-only keys; they can trigger but never redirect funds |
| Debt-ledger settlement | On-chain verification — the burn amount is provable |

Audit history and findings: [`docs/audit.md`](docs/audit.md).

## Out of scope

- Vulnerabilities in upstream OP Stack components unchanged by OMNICOR
  (report them to Optimism directly)
- Issues requiring physical access to operator infrastructure
- The TAKSI platform backend (separate repository and policy)
