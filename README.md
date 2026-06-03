# celo-dbt

dbt project for Celo builder-code attribution. Reads from Dune's curated Celo tables, decodes the attribution trailer that builders embed in transaction calldata, and writes two enriched tables back to Dune for downstream analytics.

## The models

| Model | Grain | Source | Purpose |
| --- | --- | --- | --- |
| [`transactions_attributed`](models/attribution/transactions_attributed.sql) | one row per transaction | `celo.transactions` | All Celo transactions with calldata long enough to carry an attribution payload (`varbinary_length(data) > 18`), with the builder code parsed out of the trailing bytes. |
| [`transfers_attributed`](models/attribution/transfers_attributed.sql) | one row per transfer event | `tokens.transfers` (filtered to `blockchain = 'celo'`) LEFT JOIN `transactions_attributed` on `tx_hash` | Celo token transfers with builder-code attribution attached at the transfer grain, so analytics can roll up attribution across token activity. |
| [`buildercode_daily_metric`](models/attribution/buildercode_daily_metric.sql) | one row per (day, builder_code) | `transfers_attributed` + `celo.transactions` + `prices.day` | Daily aggregates per builder: USD volume, transaction count, unique sender addresses, and chain fees paid (in USD, accounting for non-CELO gas tokens via fee_currency mapping). |

### How attribution is decoded

Each builder-tagged Celo transaction carries a trailer in its calldata:

```
... [variable-length builder code][1 byte: code length][1 byte: schema_id (0x00)][16 bytes: marker (0x80218021…)]
```

The model extracts that trailer, validates the 16-byte marker + schema id + length byte, and decodes the UTF-8 builder code. Compound payloads like `"minipay,celo_b057492a"` are split into two columns:

| Column | Type | Example value |
| --- | --- | --- |
| `has_builder_code` | bool | `true` |
| `multi_code` | varchar | `"minipay,celo_b057492a"` |
| `builder_code` | varchar | `"minipay"` |
| `builder_code2` | varchar | `"celo_b057492a"` (NULL if single-part) |

### Materialization

Both models are `incremental`, strategy `delete+insert`. Source-side lookback is 6 hours inside `is_incremental()` to absorb GitHub Actions cron jitter and Dune source-indexing delay. Historical floor is `2026-05-01` — adjust in the model SQL if you need older data.

## Getting started locally

### Prerequisites

- **Python 3.12 or 3.13** (3.14 will fail — `pydantic-core` won't build against it)
- [uv](https://github.com/astral-sh/uv)
- Dune team API key with write access to the **Celo team workspace**

### 1. Clone and install

```bash
git clone <this-repo-url>
cd celo-dbt
uv sync
```

If `uv sync` errors on `pydantic-core`, your venv picked up Python 3.14:

```bash
rm -rf .venv
uv python pin 3.12
uv sync
```

### 2. Set env vars

```bash
export DUNE_API_KEY='<your_celo_team_api_key>'   # generate inside the Celo team workspace
export DUNE_TEAM_NAME=celo
export DEV_SCHEMA_SUFFIX=<your_name>             # optional — gives you a personal dev schema
```

Use single quotes for the key. Add to `~/.zshrc` or `~/.bashrc` to persist.

The API key **must be generated from inside the Celo team workspace** on dune.com (not your personal account) — a personal key will read fine but get `access denied` on writes.

### 3. Verify connection and build

```bash
uv run dbt deps                                                  # install dbt_utils
uv run dbt debug                                                  # confirm connection (expect "All checks passed!")
uv run dbt run  --select +transfers_attributed                    # build both models; + brings in upstream
uv run dbt test --select transactions_attributed transfers_attributed
```

Run the build a second time to exercise the incremental path:

```bash
uv run dbt run --select +transfers_attributed
```

### 4. Spot-check the data

```sql
-- replace 'chidi' with your DEV_SCHEMA_SUFFIX
select 'transactions' as model, count(*) from dune.celo__tmp_chidi.transactions_attributed
union all
select 'transfers',           count(*) from dune.celo__tmp_chidi.transfers_attributed;

select has_builder_code, count(*)
from dune.celo__tmp_chidi.transactions_attributed
group by 1;
```

## Where the data lands

Schema names are auto-managed by [`macros/dune_dbt_overrides/get_custom_schema.sql`](macros/dune_dbt_overrides/get_custom_schema.sql) — never set `schema:` in a model config.

| Target | `DEV_SCHEMA_SUFFIX` | Output schema |
| --- | --- | --- |
| `dev` (default) | unset | `celo__tmp_` |
| `dev` | `chidi` | `celo__tmp_chidi` |
| `dev` | `pr42` (set by CI) | `celo__tmp_pr42` |
| `prod` | (ignored) | `celo` |

Querying from the Dune SQL editor requires the `dune` catalog prefix:

```sql
select * from dune.celo.transactions_attributed limit 100;        -- prod
select * from dune.celo__tmp_chidi.transfers_attributed limit 100; -- your dev schema
```

## Common commands

```bash
uv run dbt run  --select +transfers_attributed                    # build both models incrementally
uv run dbt run  --select +transfers_attributed --full-refresh     # full rebuild from historical floor
uv run dbt run  --select transactions_attributed                  # just the parent
uv run dbt test --select transactions_attributed transfers_attributed
uv run dbt compile --select +transfers_attributed                 # see compiled SQL without running
uv run dbt docs generate && uv run dbt docs serve                 # browse model docs locally
```

To run against prod from your machine (rare — usually CI does this):

```bash
uv run dbt run --select +transfers_attributed --target prod
```

## CI/CD

Three GitHub Actions workflows in [.github/workflows/](.github/workflows/):

| Workflow | File | Trigger | What it does |
| --- | --- | --- | --- |
| **PR CI** | [`dbt_ci.yml`](.github/workflows/dbt_ci.yml) | Pull requests | Builds and tests **modified** models into a per-PR isolated schema (`celo__tmp_pr{number}`) using `DEV_SCHEMA_SUFFIX=pr{number}`. |
| **Deploy on merge** | [`dbt_deploy.yml`](.github/workflows/dbt_deploy.yml) | Push to `main` + manual `workflow_dispatch` | `--full-refresh`es modified models in prod, then snapshots `manifest.json` for the next state comparison. |
| **Scheduled prod** | [`dbt_prod.yml`](.github/workflows/dbt_prod.yml) | Cron `'0 * * * *'` (hourly, see caveat) + manual | Incremental run + tests of all non-view production models. |

### GitHub repo setup (one-time)

Settings → Secrets and variables → Actions:

- **Secret** `DUNE_API_KEY` — Celo team API key with write permissions
- **Variable** `DUNE_TEAM_NAME` — `celo`

### Scheduled cron caveat

`dbt_prod.yml` is set to hourly, but GitHub Actions cron is **best-effort**. In practice, scheduled runs fire every ~3 hours during periods of platform load. That's why the model lookback is 6 hours rather than 2 — it absorbs the cron jitter without silently missing late-arriving source rows.

If you need true hourly cadence, you need an external scheduler (e.g. a small VM calling `gh workflow run`) rather than GH's own cron.

### Promoting a new model to prod

1. Build and verify locally (`uv run dbt run --select +your_model`).
2. Open a PR — the PR CI workflow builds it into `celo__tmp_pr{number}`.
3. Merge to `main` — the deploy workflow runs `--full-refresh` on modified models.
4. Subsequent scheduled runs handle incremental refreshes automatically. No manual changes to `dbt_prod.yml` needed; the workflow picks up new models via `--exclude config.materialized:view`.

## Project layout

```
models/attribution/
  transactions_attributed.sql    # parent — parses calldata trailer
  transfers_attributed.sql       # joins transfers to attribution
  buildercode_daily_metric.sql   # daily aggregates per builder code
  _schema.yml                    # column docs + tests for all models
  _sources.yml                   # celo.transactions, tokens.transfers, prices.day
macros/dune_dbt_overrides/       # schema naming, post-hooks (DO NOT modify)
.github/workflows/               # CI/CD (see above)
profiles.yml                     # Trino/Dune connection (reads env vars)
dbt_project.yml                  # project config
```
