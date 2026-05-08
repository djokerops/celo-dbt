{{
  config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='hash',
    alias='transactions_attributed'
  )
}}


WITH raw AS (
  SELECT
    block_time,
    block_date,
    block_number,
    value,
    gas_limit,
    gas_price,
    gas_used,
    max_fee_per_gas,
    max_priority_fee_per_gas,
    priority_fee_per_gas,
    nonce,
    index,
    success,
    "from",
    "to",
    block_hash,
    hash,
    type,
    access_list,
    chain_id,
    fee_currency,
    data AS calldata,
    varbinary_length(data) AS calldata_len
   FROM {{ source('celo', 'transactions') }}
   WHERE varbinary_length(data) > 18
     AND block_date >= date('2026-04-30')
     AND block_time >= timestamp '2026-04-30 23:22:42'
   {% if is_incremental() %}
     AND block_date >= current_date - interval '1' day
     AND block_time >= now() - interval '2' hour
   {% endif %}
 ), 

 parsed AS (
  SELECT
    *,
    -- Last 16 bytes: marker
    varbinary_substring(calldata, calldata_len - 15, 16)   AS tail_marker,
    -- Byte 17 from end: schema_id
    varbinary_substring(calldata, calldata_len - 16, 1)    AS schema_id,
    -- Byte 18 from end: code length
    CAST(
      varbinary_to_uint256(
        varbinary_substring(calldata, calldata_len - 17, 1)
      ) AS bigint
    ) AS code_len
  FROM raw
)

SELECT
    block_time,
    block_date,
    block_number,
    hash,
    value,
    gas_limit,
    gas_price,
    gas_used,
    max_fee_per_gas,
    max_priority_fee_per_gas,
    priority_fee_per_gas,
    nonce,
    index,
    success,
    "from",
    "to",
    block_hash,
    type,
    access_list,
    chain_id,
    fee_currency,
  CASE
    WHEN tail_marker = 0x80218021802180218021802180218021
     AND schema_id   = 0x00
     AND code_len    BETWEEN 1 AND 255
     AND calldata_len > (17 + code_len)
    THEN true
    ELSE false
  END AS has_builder_code,
  CASE
    WHEN tail_marker = 0x80218021802180218021802180218021
     AND schema_id   = 0x00
     AND code_len    BETWEEN 1 AND 255
     AND calldata_len > (17 + code_len)
    THEN from_utf8(
           varbinary_substring(calldata, calldata_len - 17 - code_len, code_len)
         )
    ELSE NULL
  END AS builder_code
FROM parsed

 