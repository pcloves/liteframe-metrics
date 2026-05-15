# CardFrame VM Cluster — AGENTS.md

## Quick start

```bash
cp .env.example .env     # edit HOST_IP, GRAFANA_CLIENT_SECRET, etc.
bash init.sh              # scripts/manage.sh init: auth generate → compose up → kc setup → main org/user → sync oauth-mapping
```

Prerequisites on host: `curl`, `jq`, `docker`, **mikefarah/yq** v4.18+ (NOT the Python `yq`).

## .env

Required vars: `HOST_IP`, `KC_PORT`, `GRAFANA_PORT`, `KC_REALM`, `KC_BOOTSTRAP_ADMIN_PASS`, `KC_ADMIN_PASS`,
`GRAFANA_CLIENT_SECRET`, `VMADMIN_PASS`.

`.env` is gitignored — always check `.env.example` for the canonical list.

`VM_RETENTION_PERIOD` controls VictoriaMetrics storage retention for all `vmstorage-*` nodes and defaults to `90d`.
Keep the value consistent across storage nodes.

## Architecture

vmauth is the single auth gateway (port 8427):

| Direction            | Auth                  | Route                                                               |
|----------------------|-----------------------|---------------------------------------------------------------------|
| **Read**             | Basic Auth per-org    | `vmauth → vmselect` — tenant from auth config (per-org credentials) |
| **Write** (internal) | Basic Auth `vmadmin`  | `vmauth → vminsert` — tenant `0` (all data)                         |
| **Write** (tenant)   | Basic Auth per-tenant | `vmauth → vminsert` — tenant from auth config                       |

Each tenant = Keycloak user in `{org}` group + vmauth auth entry + Grafana org. JWT `groups` claim maps to Grafana Org
via `org_attribute_path=groups` and `org_mapping`. Role groups: `role-admin` → Grafana Admin, `role-editor` → Grafana
Editor.

## Commands

| Action                                        | Command                                                                                                                                                                                                          |
|-----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Full initialization                           | `bash scripts/manage.sh init`                                                                                                                                                                                    |
| Setup Keycloak base config                    | `bash scripts/manage.sh kc setup`                                                                                                                                                                                |
| Setup admin org                               | `bash scripts/manage.sh org add --main`                                                                                                                                                                          |
| Add tenant org + group                        | `bash scripts/manage.sh org add <org-name> <grafana-org-name> [--vm-account-id <id>] [--vmauth-password <password>] [--allow-duplicate-account-id] [--use-existing-grafana-org]`                                 |
| Update tenant org metadata                    | `bash scripts/manage.sh org update <org-name> [--grafana-org-name <name>] [--vm-account-id <id>] [--vmauth-password <password>] [--rotate-password] [--allow-duplicate-account-id] [--use-existing-grafana-org]` |
| Add/update user                               | `bash scripts/manage.sh user add <username> <password> <email> <role>` (role: admin/editor/viewer/grafanaAdmin; replaces previous Grafana role group)                                                            |
| Add user to org                               | `bash scripts/manage.sh org user add <org-name> <username>`                                                                                                                                                      |
| Remove user from org                          | `bash scripts/manage.sh org user delete <org-name> <username>`                                                                                                                                                   |
| List user groups                              | `bash scripts/manage.sh user groups <username>`                                                                                                                                                                  |
| Disable tenant user                           | `bash scripts/manage.sh user delete <username>` (re-enable in Keycloak)                                                                                                                                          |
| Delete tenant user                            | `bash scripts/manage.sh user delete <username> --force`                                                                                                                                                          |
| Sync derived config                           | `bash scripts/manage.sh sync all [--prune-stale]`                                                                                                                                                                |
| Show org stats                                | `bash scripts/manage.sh stats org [--format table\|csv] [--output <file>]`                                                                                                                                       |
| Show user stats                               | `bash scripts/manage.sh stats user [--format table\|csv] [--output <file>]`                                                                                                                                      |
| Show config health                            | `bash scripts/manage.sh stats health [--format table\|csv] [--output <file>]`                                                                                                                                    |
| Regenerate auth config                        | `bash scripts/manage.sh auth generate`                                                                                                                                                                           |
| Hot-reload vmauth                             | `docker compose exec vmauth kill -HUP 1`                                                                                                                                                                         |
| Import dashboards (skip existing)             | `bash scripts/manage.sh dashboard import <org-name>`                                                                                                                                                            |
| Import dashboards (force overwrite)           | `bash scripts/manage.sh dashboard import <org-name> --overwrite`                                                                                                                                                |
| Import platform dashboards into main org      | `bash scripts/manage.sh dashboard import --main [--overwrite]`                                                                                                                                                   |
| Import tenant dashboards into all tenant orgs | `bash scripts/manage.sh dashboard import --all-tenants [--overwrite]`                                                                                                                                            |

`bash scripts/manage.sh --help` presents a layered CLI guide, and most scopes support their own `--help` entry points,
for example `bash scripts/manage.sh org --help`, `bash scripts/manage.sh org add --help`,
`bash scripts/manage.sh org update --help`, `bash scripts/manage.sh user add --help`,
`bash scripts/manage.sh sync --help`, `bash scripts/manage.sh stats --help`, and
`bash scripts/manage.sh dashboard import --help`.

`sync tenant-auth --all --prune-stale` accepts the stale-prune flag for old workflows, but vmauth entries are now rendered
directly from `vmauth/templates/*.yaml` and Keycloak group metadata into `vmauth/auth.yaml`, so there are no per-tenant
auth files to prune.

`stats org`, `stats user`, and `stats health` are read-only reporting commands. They default to table output and support
CSV via `--format csv`; `--output <file>.csv` also selects CSV automatically when `--format` is omitted. Multi-value
user group fields are joined with `;` inside one CSV cell.

**Order matters** for new tenants: `bash scripts/manage.sh org add ...` first (creates org + datasource + dashboards),
then `bash scripts/manage.sh user add ...`, then `bash scripts/manage.sh org user add ...`.

`user add` is an idempotent upsert for user identity and Grafana role only: it ensures the Keycloak user exists, syncs
email/password, and replaces any previous Grafana role group. `viewer` means no `role-*` group, so switching an existing
admin/editor user to viewer removes the old role group. Org membership is Keycloak group membership managed separately
via `org user add/delete`.

All management commands write timestamped logs to `logs/manage-YYYYMMDD.log` and print the same operational progress in
the terminal.

**Org naming:** The first parameter `<org-name>` is the internal English name (used for vmauth auth, KC group name,
dashboard UID suffix). The second parameter `<grafana-org-name>` is the Grafana org name (can be Chinese) and must be
unique by default. OAuth org mapping uses Grafana org ID (immutable), so renaming the org in Grafana UI won't break
auth.

Tenant `vm-account-id` values are stored in Keycloak group `metrics_account_id` attributes, auto-assigned when omitted,
and must be unique by default. Tenant vmauth Basic Auth passwords are stored in Keycloak group `vmauth_password`
attributes, auto-generated when omitted, and printed by `org add` after the org is ready. Re-running the same org add
command is still idempotent; to intentionally reuse a VM account ID across different org groups, add
`--allow-duplicate-account-id`. To bind a new Keycloak group to an existing Grafana org that is not already bound to
another group, add `--use-existing-grafana-org`.

Use `org update` to change an existing tenant's Grafana org binding/name, `vm-account-id`, or vmauth Basic Auth
password. `--rotate-password` generates and stores a new vmauth password, rewrites the vmauth auth entry, updates the
Grafana datasource, reloads vmauth, and prints the resulting credentials. By default `--grafana-org-name` only renames
the current Grafana org when the target name is new; use `--use-existing-grafana-org` to rebind to an existing unbound
Grafana org, update OAuth mappings, and refresh the datasource in that org.

**Main Org mapping:** Grafana built-in `Main Org.` (org ID `1`) is fixed to Keycloak group `org-main`. `org add --main`
is the only user-facing command that uses `--main`; all membership commands should use the internal group key
`org-main`, for example `bash scripts/manage.sh org user add org-main admin`.

## File layout

| Path                                | Purpose                                                                                                                 |
|-------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| `vmauth/templates/`                 | vmauth route templates for internal vmadmin and tenant auth entries                                                     |
| `vmauth/auth.yaml`                  | Generated output from templates + Keycloak metadata (gitignored, generated by `scripts/manage.sh auth generate`)        |
| `scripts/manage.sh`                 | Unified management CLI                                                                                                  |
| `scripts/lib/`                      | Shared Bash libraries for logging, env, HTTP, Grafana, Keycloak, vmauth, dashboards, and Docker                         |
| `docs/`                             | Architecture doc and Keycloak setup guide (Chinese)                                                                     |
| `grafana/dashboards/platform/`      | Platform dashboard templates for Main Org (VictoriaMetrics cluster, vmagent, vmalert, vmauth, tenant/query/alert stats) |
| `grafana/dashboards/tenants/`       | Per-tenant dashboard templates (imported by `scripts/manage.sh dashboard import <org-name>`)                            |
| `vmalert/rules/`                    | Alerting rules (health alerts for VM components)                                                                        |
| `alertmanager/config/`              | Currently routes to blackhole — configure receiver for real notifications                                               |
| `vmagent/scrape.yaml`               | Scrapes VM cluster component metrics                                                                                    |

## Commit conventions

This project follows [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <description>

[optional body]
```

Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `style`, `ci`.

## Gotchas

- Keycloak init is **two-phase**: bootstrap admin (disabled after setup) → permanent admin. Scripts are idempotent.
- vmauth `auth.yaml` is **not** checked into git — it is generated. Never edit it directly.
- Grafana datasource `vmauth-cluster` (uid `vmauth-cluster`) is created per-org by `scripts/manage.sh org add` using
  Basic Auth (per-org credentials → vmauth `/select/prometheus` → tenant-scoped Prometheus). Dashboard imports normalize datasource
  references to this UID.
- Main Org is the platform/admin observability org. It imports `grafana/dashboards/platform/` only; tenant orgs import
  `grafana/dashboards/tenants/` only.
- Dashboard UIDs are suffixed with the Keycloak group name (`org-main`, `org-test`, etc.) to keep Grafana dashboard
  identity aligned with OAuth group mapping.
- Admin user is created via the same flow as tenant users: `scripts/manage.sh org add --main`,
  `scripts/manage.sh user add admin <pass> <email> grafanaAdmin`, then `scripts/manage.sh org user add org-main admin`.
  The `org-main` group maps to `Main Org.` in Grafana, and `role-grafanaAdmin` grants the Grafana server admin role.
- Alertmanager has no receiver configured (routes to `blackhole`). Configure a real receiver before expecting alerts.
