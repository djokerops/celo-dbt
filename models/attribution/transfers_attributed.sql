{{
  config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='unique_key',
    alias='transfers_attributed'
  )
}}

WITH transfers AS (
  SELECT
    unique_key,
    blockchain,
    block_month,
    block_date,
    block_time,
    block_number,
    tx_hash,
    evt_index,
    trace_address,
    token_standard,
    tx_from,
    tx_to,
    tx_index,
    "from",
    "to",
    contract_address,
    symbol,
    amount_raw,
    amount,
    price_usd,
    amount_usd,
    _updated_at
  FROM {{ source('tokens', 'transfers') }}
  WHERE blockchain = 'celo'
    AND block_date >= date('2026-05-01')
    AND block_time >= timestamp '2026-05-01 23:22:42'
  {% if is_incremental() %}
    AND block_date >= current_date - interval '1' day
    AND block_time >= now() - interval '6' hour
  {% endif %}
),

attributed AS (
  SELECT
    hash,
    has_builder_code,
    multi_code,
    builder_code,
    builder_code2
  FROM {{ ref('transactions_attributed') }}
  WHERE block_date >= date('2026-05-01')
  {% if is_incremental() %}
    AND block_date >= current_date - interval '1' day
    AND block_time >= now() - interval '6' hour
  {% endif %}
)

SELECT
    t.unique_key,
    t.blockchain,
    t.block_month,
    t.block_date,
    t.block_time,
    t.block_number,
    t.tx_hash,
    t.evt_index,
    t.trace_address,
    t.token_standard,
    t.tx_from,
    t.tx_to,
    t.tx_index,
    t."from",
    t."to",
    t.contract_address,
    t.symbol,
    t.amount_raw,
    t.amount,
    t.price_usd,
    t.amount_usd,
    t._updated_at,
    COALESCE(a.has_builder_code, false)   AS has_builder_code,
    a.multi_code,    
    a.builder_code,                       
    a.builder_code2                      
FROM transfers AS t
LEFT JOIN attributed AS a ON t.tx_hash = a.hash