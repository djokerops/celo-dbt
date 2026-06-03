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
        COUNT(DISTINCT tx_hash)         AS tx_count,
        COUNT(DISTINCT user_address)    AS unique_addresses
    FROM attributed_transfers
    GROUP BY day, app_code
),

tagged_txs AS (
    SELECT DISTINCT
        day,
        tx_hash,
        app_code
    FROM attributed_transfers
),

tx_fees AS (
    SELECT
        t.day,
        t.app_code,
        tx.hash,
        CAST(tx.gas_used AS DOUBLE) * CAST(tx.gas_price AS DOUBLE) / 1e18  AS fee_token_amount,
        CASE
            WHEN tx.fee_currency = 0x2f25deb3848c207fc8e0c34035b3ba7fc157602b
                THEN 0xcebA9300f2b948710d2653dD7B07f33A8B32118C  -- USDC adapter → USDC
            WHEN tx.fee_currency = 0x0e2a3e05bc9a16f5292a6170456a710cb89c6f72
                THEN 0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e  -- USDT adapter → USDT
            WHEN tx.fee_currency IS NULL
              OR tx.fee_currency = 0x0000000000000000000000000000000000000000
                THEN 0x471EcE3750Da237f93B8E339c536989b8978a438  -- native CELO
            ELSE tx.fee_currency                                  -- price the fee_currency contract directly
        END AS price_address
    FROM tagged_txs t
    JOIN {{ source('celo', 'transactions') }} tx
        ON t.tx_hash = tx.hash
       AND tx.block_date >= date('2026-05-01')
       {% if is_incremental() %}
       AND tx.block_date >= current_date - interval '2' day
       {% endif %}
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
    tm.day,
    tm.builder_code,
    tm.volume_usd,
    tm.tx_count,
    tm.unique_addresses,
    COALESCE(fm.chain_fees_usd, 0) AS chain_fees_usd
FROM transfer_metrics tm
LEFT JOIN fee_metrics fm
    ON tm.day = fm.day
   AND tm.builder_code = fm.app_code
