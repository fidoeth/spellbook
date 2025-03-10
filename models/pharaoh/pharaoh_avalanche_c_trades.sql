{{ config(
    schema = 'pharaoh_avalanche_c'
    , alias = 'trades'
    , partition_by = ['block_month']
    , materialized = 'incremental'
    , file_format = 'delta'
    , incremental_strategy = 'merge'
    , unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index']
    )
}}

{% set project_start_date = '2023-12-10' %}

WITH dexs AS
(
    SELECT
        t.evt_block_time AS block_time
        ,t.recipient AS taker
        ,CAST(NULL AS VARBINARY) AS maker
        ,CASE
            WHEN router.evt_tx_hash IS NULL
                THEN CASE WHEN amount0 < INT256 '0' THEN abs(amount0) ELSE abs(amount1) END
                ELSE router.amountOut
            END AS token_bought_amount_raw
        ,CASE
            WHEN router.evt_tx_hash IS NULL
                THEN CASE WHEN amount0 < INT256 '0' THEN abs(amount1) ELSE abs(amount0) END
                ELSE router.inputAmount
            END AS token_sold_amount_raw
        ,NULL AS amount_usd
        ,CASE
            WHEN router.evt_tx_hash IS NULL
                THEN CASE WHEN amount0 < INT256 '0' THEN f.token0 ELSE f.token1 END
                ELSE router.outputToken
            END AS token_bought_address
        ,CASE
            WHEN router.evt_tx_hash IS NULL
                THEN CASE WHEN amount0 < INT256 '0' THEN f.token1 ELSE f.token0 END
                ELSE router.inputToken
            END AS token_sold_address
        ,t.contract_address as project_contract_address
        ,t.evt_tx_hash AS tx_hash
        ,t.evt_index
    FROM
        {{ source('pharaoh_avalanche_c', 'ClPool_evt_Swap') }} t
    INNER JOIN 
        {{ source('pharaoh_avalanche_c', 'ClPoolFactory_evt_PoolCreated') }} f
        ON f.pool = t.contract_address
    LEFT JOIN {{ source('glacier_avalanche_c', 'OdosRouterV2_evt_Swap') }} AS router
        ON t.evt_tx_hash = router.evt_tx_hash
        AND t.evt_index + 2 = router.evt_index
    {% if is_incremental() %}
    WHERE {{ incremental_predicate('t.evt_block_time') }}
    {% endif %}
)
SELECT
    'avalanche_c' AS blockchain
    ,'pharaoh' AS project
    ,'1' AS version
    ,CAST(date_trunc('day', dexs.block_time) AS date) AS block_date
    ,CAST(date_trunc('month', dexs.block_time) AS date) AS block_month
    ,dexs.block_time
    ,erc20a.symbol AS token_bought_symbol
    ,erc20b.symbol AS token_sold_symbol
    ,case
        when lower(erc20a.symbol) > lower(erc20b.symbol) then concat(erc20b.symbol, '-', erc20a.symbol)
        else concat(erc20a.symbol, '-', erc20b.symbol)
    end as token_pair
    ,CAST(dexs.token_bought_amount_raw AS UINT256) / power(10, erc20a.decimals) AS token_bought_amount
    ,CAST(dexs.token_sold_amount_raw AS UINT256) / power(10, erc20b.decimals) AS token_sold_amount
    ,CAST(dexs.token_bought_amount_raw AS UINT256)  AS token_bought_amount_raw
    ,CAST(dexs.token_sold_amount_raw AS UINT256)  AS token_sold_amount_raw
    ,coalesce(
        dexs.amount_usd
        ,(CAST(dexs.token_bought_amount_raw AS UINT256) / power(10, p_bought.decimals)) * p_bought.price
        ,(CAST(dexs.token_sold_amount_raw AS UINT256) / power(10, p_sold.decimals)) * p_sold.price
    ) AS amount_usd
    ,dexs.token_bought_address
    ,dexs.token_sold_address
    ,coalesce(dexs.taker, tx."from") AS taker -- subqueries rely on this COALESCE to avoid redundant joins with the transactions table
    ,dexs.maker
    ,dexs.project_contract_address
    ,dexs.tx_hash
    ,tx."from" AS tx_from
    ,tx.to AS tx_to
    ,dexs.evt_index
FROM dexs
INNER JOIN 
    {{ source('avalanche_c', 'transactions') }} tx
    ON tx.hash = dexs.tx_hash
    {% if not is_incremental() %}
    AND tx.block_time >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND {{ incremental_predicate('tx.block_time') }}
    {% endif %}
LEFT JOIN {{ source('tokens', 'erc20') }} erc20a
    ON erc20a.contract_address = dexs.token_bought_address 
    AND erc20a.blockchain = 'avalanche_c'
LEFT JOIN {{ source('tokens', 'erc20') }} erc20b
    ON erc20b.contract_address = dexs.token_sold_address
    AND erc20b.blockchain = 'avalanche_c'
LEFT JOIN {{ source('prices', 'usd') }} p_bought
    ON p_bought.minute = date_trunc('minute', dexs.block_time)
    AND p_bought.contract_address = dexs.token_bought_address
    AND p_bought.blockchain = 'avalanche_c'
    {% if not is_incremental() %}
    AND p_bought.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND {{ incremental_predicate('p_bought.minute') }}
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_sold
    ON p_sold.minute = date_trunc('minute', dexs.block_time)
    AND p_sold.contract_address = dexs.token_sold_address
    AND p_sold.blockchain = 'avalanche_c'
    {% if not is_incremental() %}
    AND p_sold.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND {{ incremental_predicate('p_sold.minute') }}
    {% endif %}
