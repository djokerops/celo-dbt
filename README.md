# celo-dbt

A dbt project that builds Celo transaction attribution data on top of Dune. The single model in this repo (`transactions_attributed`) reads raw Celo transactions, parses the builder-code attribution trailer from each transaction's calldata, and writes an enriched table back to Dune.

Built on the [dune-dbt-template](https://github.com/duneanalytics/dune-dbt-template), using `dbt-trino` against Dune's Trino API and `uv` for Python package management.

## What this project does

Each Celo transaction may carry an attribution payload in the last bytes of its `data` field:

```
... [variable-length builder code][1 byte: code length][1 byte: schema_id (0x00)][16 bytes: marker (0x80218021…)]
```

The `transactions_attributed` model:

1. Filters source rows where `varbinary_length(data) > 18` (room for the trailer)
2. Parses the trailing 16-byte marker, schema id, and code length
3. Extracts the UTF-8 builder code when the trailer is valid
4. Adds two columns to a passthrough of the source columns:
   - `has_builder_code` (boolean)
   - `builder_code` (varchar, nullable)

**Materialization:** incremental, `delete+insert`, unique key = `hash`, with a 7-day source lookback to handle late-arriving rows.

## Project layout

```
models/
  attribution/
    transactions_attributed.sql   # the model
    _schema.yml                   # column docs + tests
    _sources.yml                  # celo.transactions source
macros/dune_dbt_overrides/        # schema naming, post-hooks (do not modify)
profiles.yml                      # Trino/Dune connection (reads env vars)
dbt_project.yml                   # project config
```

## Running locally

### Prerequisites

- Python 3.12 or 3.13 (NOT 3.14 — `pydantic-core` will not build)
- [uv](https://github.com/astral-sh/uv)
- A Dune API key with access to the Celo team workspace

### 1. Clone and install

```bash
git clone <this-repo-url>
cd celo-dbt
uv sync
```

If `uv sync` fails with a `pydantic-core` build error, your venv picked up Python 3.14:

```bash
rm -rf .venv
uv python pin 3.12
uv sync
```

### 2. Set environment variables

```bash
export DUNE_API_KEY=<your_dune_api_key>     # https://dune.com/settings/api
export DUNE_TEAM_NAME=celo                  # or whatever the Dune team is called
export DEV_SCHEMA_SUFFIX=<your_name>        # optional — gives you a personal dev schema
```

To make these persistent, add them to your shell profile (`~/.zshrc` or `~/.bashrc`).

### 3. Verify and run

```bash
uv run dbt deps                                          # install dbt packages
uv run dbt debug                                         # confirm connection works
uv run dbt run  --select transactions_attributed         # build the model
uv run dbt test --select transactions_attributed         # run its tests
```

Run it twice to exercise the incremental path:

```bash
uv run dbt run --select transactions_attributed   # second run uses is_incremental()
```

## Where the data lands

Schema names are auto-managed by [`macros/dune_dbt_overrides/get_custom_schema.sql`](macros/dune_dbt_overrides/get_custom_schema.sql) — never set `schema:` in a model config.

| Target | `DEV_SCHEMA_SUFFIX` | Output schema |
| --- | --- | --- |
| `dev` (default) | unset | `{team}__tmp_` |
| `dev` | `alice` | `{team}__tmp_alice` |
| `dev` | `pr42` (set by CI) | `{team}__tmp_pr42` |
| `prod` | (ignored) | `{team}` |

To run against the production schema:

```bash
uv run dbt run --target prod --select transactions_attributed
```

To query the table from the Dune SQL editor, prepend the `dune` catalog:

```sql
select * from dune.celo__tmp_alice.transactions_attributed
```

## CI/CD

GitHub Actions workflows live in [.github/workflows/](./.github/workflows/) and are **all disabled by default**. To enable them, uncomment the trigger blocks:

- [`dbt_ci.yml`](.github/workflows/dbt_ci.yml) — runs modified models on PRs into a per-PR schema
- [`dbt_prod.yml`](.github/workflows/dbt_prod.yml) — scheduled production runs (hourly cron, currently commented out)
- [`dbt_deploy.yml`](.github/workflows/dbt_deploy.yml) — manifest snapshot for state-aware runs

GitHub setup needed before enabling:
- Secret `DUNE_API_KEY` (Settings → Secrets → Actions)
- Variable `DUNE_TEAM_NAME` (Settings → Variables → Actions)


## Common commands

```bash
uv run dbt run --select transactions_attributed                    # incremental run
uv run dbt run --select transactions_attributed --full-refresh     # rebuild from scratch
uv run dbt test --select transactions_attributed                   # run tests
uv run dbt docs generate && uv run dbt docs serve                  # browse docs locally
```

## Further reading

The [docs/](docs/) directory has the inherited template documentation:

- [docs/getting-started.md](docs/getting-started.md)
- [docs/development-workflow.md](docs/development-workflow.md)
- [docs/dbt-best-practices.md](docs/dbt-best-practices.md) — incremental patterns, lookback windows, partitioning
- [docs/testing.md](docs/testing.md)
- [docs/cicd.md](docs/cicd.md)
- [docs/troubleshooting.md](docs/troubleshooting.md)
