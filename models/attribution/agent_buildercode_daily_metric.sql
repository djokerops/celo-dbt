{{
  config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['day', 'builder_code'],
    alias='agent_daily_code_metric'
  )
}}

WITH allowlist AS (                       -- enrichment: which hackathon + display name
    SELECT code, 'agents_at_work' AS hackathon, project_name AS label
    FROM {{ source('celo_datasets', 'dataset_agents_at_work_allowlist', database='dune') }}
    UNION ALL
    SELECT code, 'defai' AS hackathon, team AS label
    FROM {{ source('celo_datasets', 'dataset_agentic_defai_allowlist', database='dune') }}
),
allow_agg AS (
    SELECT code, arbitrary(hackathon) AS hackathon, arbitrary(label) AS label
    FROM allowlist GROUP BY code
),

-- explode the suffix array, keep ONLY hackathon-format codes (slot-agnostic)
tx_hack AS (
    SELECT
        DATE_TRUNC('day', block_time) AS day,
        block_date,
        hash          AS tx_hash,
        "from"        AS user_address,
        u.code        AS code,
        CAST(gas_used AS DOUBLE) * CAST(gas_price AS DOUBLE) / 1e18 AS fee_token_amount,
        fee_currency
    FROM {{ ref('transactions_attributed') }}
    CROSS JOIN UNNEST(split(multi_code, ',')) AS u(code)
    WHERE has_builder_code
      AND regexp_like(u.code, '^celo_[0-9a-f]{12}$')
      AND block_date >= date('2026-05-01')
    {% if is_incremental() %} AND block_date >= current_date - interval '2' day {% endif %}
),
transfers_hack AS (
    SELECT
        DATE_TRUNC('day', block_time) AS day,
        tx_hash,
        u.code       AS code,
        amount_usd
    FROM {{ ref('transfers_attributed') }}
    CROSS JOIN UNNEST(split(multi_code, ',')) AS u(code)
    WHERE builder_code IS NOT NULL
      AND regexp_like(u.code, '^celo_[0-9a-f]{12}$')
      AND block_date >= date('2026-05-01')
    {% if is_incremental() %} AND block_date >= current_date - interval '2' day {% endif %}
),

tx_metrics AS (
    SELECT day, code,
           COUNT(DISTINCT tx_hash)      AS tx_count,
           COUNT(DISTINCT user_address) AS unique_addresses
    FROM tx_hack GROUP BY day, code
),
transfer_metrics AS (
    SELECT day, code,
           SUM(amount_usd)         AS volume_usd,
           COUNT(DISTINCT tx_hash) AS token_transfers_tx
    FROM transfers_hack GROUP BY day, code
),

tx_fees AS (
    SELECT
        day, code, tx_hash, fee_token_amount,
        CASE
            WHEN fee_currency = 0x2f25deb3848c207fc8e0c34035b3ba7fc157602b
                THEN 0xcebA9300f2b948710d2653dD7B07f33A8B32118C     -- USDC adapter → USDC
            WHEN fee_currency = 0x0e2a3e05bc9a16f5292a6170456a710cb89c6f72
                THEN 0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e     -- USDT adapter → USDT
            WHEN fee_currency IS NULL
              OR fee_currency = 0x0000000000000000000000000000000000000000
                THEN 0x471EcE3750Da237f93B8E339c536989b8978a438     -- native CELO
            ELSE fee_currency
        END AS price_address
    FROM tx_hack
),
token_prices AS (
    SELECT DATE_TRUNC('day', timestamp) AS day, contract_address, AVG(price) AS price
    FROM {{ source('prices', 'day') }}
    WHERE blockchain = 'celo'
      AND timestamp >= timestamp '2026-05-01 00:00:00'
    {% if is_incremental() %} AND timestamp >= current_date - interval '2' day {% endif %}
      AND contract_address IN (SELECT DISTINCT price_address FROM tx_fees)
    GROUP BY 1, 2
),
fee_metrics AS (
    SELECT f.day, f.code,
           SUM(f.fee_token_amount * COALESCE(p.price, 0)) AS chain_fees_usd
    FROM tx_fees f
    LEFT JOIN token_prices p
        ON f.day = p.day AND f.price_address = p.contract_address
    GROUP BY f.day, f.code
)

SELECT
    txm.day,
    txm.code                             AS builder_code,      -- the hackathon-format code
    COALESCE(a.hackathon, 'unlisted')    AS hackathon,
    a.label,
    (a.code IS NOT NULL)                 AS on_allowlist,
    txm.tx_count,
    txm.unique_addresses,
    COALESCE(tm.volume_usd, 0)           AS volume_usd,
    COALESCE(tm.token_transfers_tx, 0)   AS token_transfers_tx,
    COALESCE(fm.chain_fees_usd, 0)       AS chain_fees_usd
FROM tx_metrics txm
LEFT JOIN transfer_metrics tm ON tm.day = txm.day AND tm.code = txm.code
LEFT JOIN fee_metrics      fm ON fm.day = txm.day AND fm.code = txm.code
LEFT JOIN allow_agg        a  ON a.code = txm.code