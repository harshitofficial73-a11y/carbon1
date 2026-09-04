# Backend notes · Supabase

Three migrations, run in order in the SQL editor or via `supabase db push`:

| File | Contents |
| --- | --- |
| `001_schema.sql` | Enums, tables, indexes, triggers |
| `002_rls.sql` | Helper functions and row-level-security policies |
| `003_seed.sql` | Company, structure, permission matrix, periods, factors, suppliers |

## Model

Everything hangs off `companies`. Structure is `companies → clusters → units`, which is what the Admin Console's "Company structure" step writes.

`profiles` is 1:1 with `auth.users` and carries role, employee ID, approval authority, internal/external flag and status — the "ID addition" step. `profile_units` is the access scope written by "Role assignment". Auditors are the exception: they read across companies through `auditor_engagements`, which is what backs the Company switcher in the auditor's top bar.

Roles are `operator`, `gsh`, `supplier`, `auditor`, `platform`, matching the role switcher.

## Enforcement

- **Capabilities** live in `role_permissions` (company × role × capability) and are read by the `has_capability()` helper inside policies, so editing the permission matrix in the Admin Console changes real authorisation rather than only the UI.
- **Period locks** are enforced by a trigger on `activity_data`, not just by policy — a locked period rejects inserts, updates and deletes for every role including the platform admin.
- **Module locks** (`decarb`, `certifications`, `esg`) are a per-company row the client reads on boot.
- **`audit_log` is append-only** — a trigger blocks update and delete. Write one row per submission, approval, return, edit, factor change, period lock and access change.
- **tCO₂e** is computed by a trigger from `quantity × emission_factors.value`, so the client never posts a derived number.

## Storage

Create a private bucket `evidence`. Object path convention `company/<company_code>/<period>/<submission_id>/<file>`. Mirror the `evidence` table policies with storage policies keyed on the same `unit_in_scope()` helper.

## Not yet covered

- Auth hooks: on invite acceptance, insert the `profiles` row and copy `invites.unit_id` into `profile_units`.
- Edge functions for report generation and evidence-pack export.
- Scheduled job to flip `reporting_periods.state` from `future` to `open` at month start.

Tell me which of those you want next, or hand these files to your Supabase project and I will wire the prototype's screens to real queries.
