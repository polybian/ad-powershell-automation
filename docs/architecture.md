# Architecture & Design Decisions

## Scope

Five scripts (four since v1, one added in v2) around one idea: treat a CSV
as the desired state for an on-prem Active Directory lab domain, and make
every change script safe to re-run, safe to preview, and easy to audit.

```
CSV (desired state) ──► New-ADUsersFromCsv.ps1 ──────► OUs + users
CSV (desired state) ──► Sync-ADGroupMembership.ps1 ──► group membership
AD (actual state)   ──► Get-StaleADAccounts.ps1 ─────► CSV audit report
AD (actual state)   ──► Get-GPOInventory.ps1 ────────► CSV audit report
AD (actual state)   ──► Get-ADHealthReport.ps1 ──────► console + HTML (v2)
```

## v2 design notes

- **Replication without `repadmin.exe`:** `Get-ADHealthReport.ps1` reads
  replication state through `Get-ADReplicationPartnerMetadata`, which
  returns structured partner metadata (last success time, result code,
  consecutive failures) straight from the directory. Parsing `repadmin`
  text output would work, but it is locale-dependent and brittle; the
  cmdlet is the supported, testable interface.
- **HTML is a second interface, not a replacement:** CSV stays the audit
  record. HTML exists for the humans in the loop — a health snapshot or a
  drift report someone will actually read in a browser. Both HTML reports
  are self-contained (inline CSS, HTML-escaped values, no external
  assets) so the file can be archived or attached as-is.
- **Drift reports are signal, not noise:** the sync only writes the HTML
  when drift was found; a no-drift run leaves only the CSV. And the write
  goes through `Out-File`, which honors `-WhatIf` — a dry run reports
  "What if: Output to File" instead of writing, consistent with the CSV
  report (a lesson learned in validation: .NET `WriteAllText` silently
  ignores `-WhatIf` and threw on a fresh output folder).

## Design decisions

### Idempotency first

`New-ADUsersFromCsv.ps1` checks before it writes: if the OU exists it is
left alone; if the sAMAccountName exists the account is skipped and marked
`Skipped` in the run log. `Sync-ADGroupMembership.ps1` compares desired vs
actual sets and only touches the delta. Re-running any script with the same
input converges to the same state instead of erroring or duplicating —
which is exactly what you want in a provisioning run that might be
interrupted halfway.

### OU design

The templates assume a role-based layout:

```
DC=contoso,DC=example
└── OU=Users
    ├── OU=Sales
    ├── OU=Support
    └── OU=Finance
```

- Split by department so a GPO (password policy exceptions, drive mappings,
  software deployment) can target one department without touching others.
- Keep all human users under one parent (`OU=Users`) so a single
  `SearchBase` scopes audits like `Get-StaleADAccounts.ps1`.
- OUs are created with `ProtectedFromAccidentalDeletion` — a fat-fingered
  delete of a parent OU should be hard, not easy.

### Naming convention

- Accounts: `first initial + last name`, lowercase (`arivera`, `bmendez`) —
  short, predictable, and fits the legacy 20-character sAMAccountName limit
  the script enforces with a regex.
- UPN always equals `<sam>@<domain suffix>`; the script rejects rows whose
  UPN does not end with the expected suffix, catching typos and CSVs built
  for the wrong domain before anything is created.
- Groups: `GG-<purpose>` prefix for global groups (`GG-Sales`) so they are
  distinguishable from distribution lists and local groups at a glance.

### Desired-state groups, safe-by-default removal

`Sync-ADGroupMembership.ps1` treats the CSV as the source of truth for
membership, but deleting access is the risky direction, so removal is
opt-in via `-RemoveExtra`. Without it, extras are reported as `Drift` in
the report — the normal access-review workflow: a human reads the drift
report, then decides.

### Reports are the interface

Every script writes timestamped output to `logs/` or `reports/`:
per-user result CSVs, an error log for failed rows, and reconciliation
reports that include `AlreadyMember` rows. The console summary is a
convenience; the CSV is the audit record.

## Why the ActiveDirectory module over raw LDAP

- `Get-ADUser` / `New-ADUser` / `Add-ADGroupMember` already model AD
  semantics (DN escaping, attribute types, UPN handling). Raw
  `[ADSI]`/LDAP code re-implements all of it and gets the edge cases wrong.
- The module cmdlets accept pipeline input, `-WhatIf`, and consistent
  `-Identity`/`-Filter` patterns, so scripts read the same way an AD admin
  already works.
- Trade-off, stated honestly: the module requires RSAT and a Windows host
  (or a domain-joined management workstation). For a lab portfolio project
  that is the right constraint — these scripts are meant to run where AD
  admins actually run them.

## Hardening / safety notes

- **Least privilege:** run with a delegated service account that can create
  users and modify membership only under the target OUs — never Domain
  Admin for a bulk import.
- **`-WhatIf` first, always:** both write scripts implement `ShouldProcess`;
  the runbook makes a dry run step one. A `WouldCreate` / `WouldAdd` row in
  the report shows exactly what a real run would do.
- **No plaintext credentials:** the initial password is a mandatory
  `SecureString` parameter (the runbook shows `Read-Host -AsSecureString`).
  No password, real domain, or real name appears anywhere in this repo —
  all data is fictional `contoso.example`.
- **Fail per row, not per run:** one bad CSV row logs to the error file and
  the run continues; the summary reports created / skipped / failed counts.
- **Scope validation:** OU DNs are checked against the base DN and UPNs
  against the domain suffix before any write, so a malformed CSV cannot
  create objects outside the intended part of the tree.
