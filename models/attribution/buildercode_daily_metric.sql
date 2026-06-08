{{
  config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['day', 'builder_code'],
    alias='buildercode_daily_metric'
  )
}}

WITH attributed_transfers AS (
    SELECT
        DATE_TRUNC('day', block_time) AS day,
        tx_hash,
        COALESCE(NULLIF(builder_code2, ''), builder_code) AS app_code,
        "from" AS user_address,
        amount_usd
    FROM {{ ref('transfers_attributed') }}
    WHERE builder_code IS NOT NULL
      AND block_date >= date('2026-05-01')
    {% if is_incremental() %}
      AND block_date >= current_date - interval '2' day
    {% endif %}
),

transfer_metrics AS (
    SELECT
        day,
        app_code AS builder_code,
        SUM(amount_usd)                 AS volume_usd,
        COUNT(DISTINCT tx_hash)         AS token_transfers_tx,
        COUNT(DISTINCT user_address)    AS unique_addresses
    FROM attributed_transfers
    GROUP BY day, app_code
),

attributed_txs AS (
    SELECT
        DATE_TRUNC('day', block_time) AS day,
        hash AS tx_hash,
        COALESCE(NULLIF(builder_code2, ''), builder_code) AS app_code,
        gas_used,
        gas_price,
        fee_currency
    FROM {{ ref('transactions_attributed') }}
    WHERE has_builder_code
      AND block_date >= date('2026-05-01')
    {% if is_incremental() %}
      AND block_date >= current_date - interval '2' day
    {% endif %}
),

tx_metrics AS (
    SELECT
        day,
        app_code AS builder_code,
        COUNT(DISTINCT tx_hash) AS tx_count
    FROM attributed_txs
    GROUP BY day, app_code
),

tx_fees AS (
    SELECT
        day,
        app_code,
        tx_hash,
        CAST(gas_used AS DOUBLE) * CAST(gas_price AS DOUBLE) / 1e18  AS fee_token_amount,
        CASE
            WHEN fee_currency = 0x2f25deb3848c207fc8e0c34035b3ba7fc157602b
                THEN 0xcebA9300f2b948710d2653dD7B07f33A8B32118C  -- USDC adapter → USDC
            WHEN fee_currency = 0x0e2a3e05bc9a16f5292a6170456a710cb89c6f72
                THEN 0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e  -- USDT adapter → USDT
            WHEN fee_currency IS NULL
              OR fee_currency = 0x0000000000000000000000000000000000000000
                THEN 0x471EcE3750Da237f93B8E339c536989b8978a438  -- native CELO
            ELSE fee_currency                                     -- price the fee_currency contract directly
        END AS price_address
    FROM attributed_txs
),

token_prices AS (
    SELECT
        DATE_TRUNC('day', timestamp) AS day,
        contract_address,
        AVG(price) AS price
    FROM {{ source('prices', 'day') }}
    WHERE blockchain = 'celo'
      AND timestamp >= timestamp '2026-05-01 00:00:00'
    {% if is_incremental() %}
      AND timestamp >= current_date - interval '2' day
    {% endif %}
      AND contract_address IN (SELECT DISTINCT price_address FROM tx_fees)
    GROUP BY 1, 2
),

fee_metrics AS (
    SELECT
        f.day,
        f.app_code,
        SUM(f.fee_token_amount * COALESCE(p.price, 0))  AS chain_fees_usd
    FROM tx_fees f
    LEFT JOIN token_prices p
        ON f.day = p.day
       AND f.price_address = p.contract_address
    GROUP BY f.day, f.app_code
)

SELECT
    txm.day,
    txm.builder_code,
    COALESCE(tm.volume_usd, 0)         AS volume_usd,
    txm.tx_count,
    COALESCE(tm.token_transfers_tx, 0) AS token_transfers_tx,
    COALESCE(tm.unique_addresses, 0)   AS unique_addresses,
    COALESCE(fm.chain_fees_usd, 0)     AS chain_fees_usd
FROM tx_metrics txm
LEFT JOIN transfer_metrics tm
    ON tm.day = txm.day
   AND tm.builder_code = txm.builder_code
LEFT JOIN fee_metrics fm
    ON txm.day = fm.day
   AND txm.builder_code = fm.app_code
