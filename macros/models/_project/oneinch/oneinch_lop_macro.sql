{% macro 
    oneinch_lop_macro(
        blockchain
    ) 
%}



{%
    set cfg = {
        'LimitOrderProtocolV1': {
            'version': '1',
            'blockchains': ["ethereum", "bnb", "polygon", "arbitrum", "optimism"],
            'start': '2021-06-03',
            'methods': {
                'fillOrder': {
                    'maker': "substr(from_hex(order_map['makerAssetData']), 4 + 12 + 1, 20)"
                },
                'fillOrderRFQ': {
                    'maker': "substr(from_hex(order_map['makerAssetData']), 4 + 12 + 1, 20)",
                    'making_amount': "bytearray_to_uint256(substr(from_hex(order_map['makerAssetData']), 4 + 32*2 + 1, 32))",
                    'taking_amount': "bytearray_to_uint256(substr(from_hex(order_map['takerAssetData']), 4 + 32*2 + 1, 32))"
                }
            }
        },
        'LimitOrderProtocolV2': {
            'version': '2',
            'blockchains': ["ethereum", "bnb", "polygon", "arbitrum", "avalanche_c", "gnosis", "optimism"],
            'start': '2021-11-26',
            'methods': {
                'fillOrder': {},
                'fillOrderTo': {
                    'receiver': "from_hex(order_map['receiver'])"
                },
                'fillOrderToWithPermit': {
                    'receiver': "from_hex(order_map['receiver'])"
                },
                'fillOrderRFQ': {},
                'fillOrderRFQTo': {},
                'fillOrderRFQToWithPermit': {}
            }
        },
        'AggregationRouterV4': {
            'version': '2',
            'blockchains': ["ethereum", "bnb", "polygon", "arbitrum", "avalanche_c", "gnosis", "optimism", "fantom"],
            'start': '2021-11-05',
            'methods': {
                'fillOrderRFQ': {},
                'fillOrderRFQTo': {},
                'fillOrderRFQToWithPermit': {}
            }
        },
        'AggregationRouterV5': {
            'version': '3',
            'blockchains': ["ethereum", "bnb", "polygon", "arbitrum", "avalanche_c", "gnosis", "optimism", "fantom", "base", "zksync"],
            'start': '2022-11-04',
            'methods': {
                'fillOrder': {
                    'order_hash': 'output_2'
                },
                'fillOrderTo': {
                    'order': '"order_"',
                    'making_amount': 'output_actualMakingAmount',
                    'taking_amount': 'output_actualTakingAmount',
                    'order_hash': 'output_orderHash',
                    'receiver': "from_hex(order_map['receiver'])"
                },
                'fillOrderToWithPermit': {
                    'order_hash': 'output_2',
                    'receiver': "from_hex(order_map['receiver'])"
                },
                'fillOrderRFQ': {
                    'order_hash': 'output_2'
                },
                'fillOrderRFQTo': {
                    'making_amount': 'output_filledMakingAmount',
                    'taking_amount': 'output_filledTakingAmount',
                    'order_hash': 'output_orderHash'
                },
                'fillOrderRFQToWithPermit': {
                    'order_hash': 'output_2'
                },
                'fillOrderRFQCompact': {
                    'making_amount': 'output_filledMakingAmount',
                    'taking_amount': 'output_filledTakingAmount',
                    'order_hash': 'output_orderHash'
                }
            }
        }
    }
%}



with

orders as (
    {% for contract, contract_data in cfg.items() if blockchain in contract_data['blockchains'] %}
        select * from ({% for method, method_data in contract_data.methods.items() %}
            select
                call_block_number as block_number
                , call_block_time as block_time
                , call_tx_hash as tx_hash
                , '{{ contract }}' as contract_name
                , '{{ contract_data['version'] }}' as protocol_version
                , '{{ method }}' as method
                , call_trace_address
                , contract_address as call_to
                , call_success
                , from_hex(order_map['makerAsset']) as maker_asset
                , from_hex(order_map['takerAsset']) as taker_asset
                , {{ method_data.get("maker", "from_hex(order_map['maker'])") }} as maker
                , {{ method_data.get("receiver", "null") }} as receiver
                , {{ method_data.get("making_amount", "output_0") }} as making_amount
                , {{ method_data.get("taking_amount", "output_1") }} as taking_amount
                , {{ method_data.get("order_hash", "null") }} as order_hash
            from (
                select *, cast(json_parse({{ method_data.get("order", '"order"') }}) as map(varchar, varchar)) as order_map
                from {{ source('oneinch_' + blockchain, contract + '_call_' + method) }}
                {% if is_incremental() %} 
                    where {{ incremental_predicate('call_block_time') }}
                {% endif %}
            )
            {% if not loop.last %} union all {% endif %}
        {% endfor %})
        join (
            select
                tx_hash
                , trace_address as call_trace_address
                , "from" as call_from
                , substr(input, 1, 4) as call_selector
                , gas_used as call_gas_used
                , substr(input, length(input) - mod(length(input) - 4, 32) + 1) as remains
                , output as call_output
                , error as call_error
                , block_number
            from {{ source(blockchain, 'traces') }}
            where
                {% if is_incremental() %} 
                    {{ incremental_predicate('block_time') }}
                {% else %}
                    block_time >= timestamp '{{ contract_data['start'] }}'
                {% endif %}
                and call_type = 'call'
        ) using(block_number, tx_hash, call_trace_address)
        {% if not loop.last %} union all {% endif %}
    {% endfor %}
)

-- output --

select
    '{{ blockchain }}' as blockchain
    , block_number
    , block_time
    , tx_hash
    , tx_from
    , tx_to
    , tx_success
    , tx_nonce
    , tx_gas_used
    , tx_gas_price
    , tx_priority_fee_per_gas
    , contract_name
    , 'LOP' as protocol
    , protocol_version
    , method
    , call_selector
    , call_trace_address
    , call_from
    , call_to
    , call_success
    , call_gas_used
    , call_output
    , call_error
    , maker
    , receiver
    , maker_asset
    , making_amount
    , taker_asset
    , taking_amount
    , order_hash
    , concat(cast(length(remains) as bigint), if(length(remains) > 0
        , transform(sequence(1, length(remains), 4), x -> bytearray_to_bigint(reverse(substr(reverse(remains), x, 4))))
        , array[bigint '0']
    )) as remains
    , date_trunc('minute', block_time) as minute
    , date(date_trunc('month', block_time)) as block_month 
from (
    {{
        add_tx_columns(
            model_cte = 'orders'
            , blockchain = blockchain
            , columns = ['from', 'to', 'success', 'nonce', 'gas_price', 'priority_fee_per_gas', 'gas_used']
        )
    }}
)

{% endmacro %}
