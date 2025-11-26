#!/bin/bash

set -e

export CLUSTER_ENDPOINT="http://localhost:19530"
export TOKEN="root:Milvus"

echo "Creating Milvus collections..."
echo "Endpoint: $CLUSTER_ENDPOINT"
echo ""

# Create creation collection
echo "1. Creating 'creation' collection..."
export bm25Function='{
    "name": "title_bm25_emb",
    "type": "BM25",
    "inputFieldNames": ["title"],
    "outputFieldNames": ["title_embeddings"],
    "params": {}
}'
export schema='{
        "autoId": false,
        "enableDynamicField": true,
        "functions": ['"$bm25Function"'],
        "fields": [
            {
                "fieldName": "creation_id",
                "dataType": "Int64",
                "isPrimary": true
            },
            {
                "fieldName": "rec_embeddings",
                "dataType": "FloatVector",
                "elementTypeParams": {
                    "dim": "1024"
                }
            },
            {
                "fieldName": "title",
                "dataType": "VarChar",
                "elementTypeParams": {
                    "max_length": 200,
                    "enable_analyzer": true,
                    "enable_match": true,
                    "analyzer_params": {"type": "chinese"}
                }
            },
            {
                "fieldName": "title_embeddings",
                "dataType": "SparseFloatVector"
            }
        ]
    }'
export indexParams='[
        {
            "fieldName": "creation_id",
            "indexName": "creation_id_index",
            "indexType": "AUTOINDEX"
        },
        {
            "fieldName": "rec_embeddings",
            "metricType": "COSINE",
            "indexName": "rec_embeddings_index",
            "indexType": "HNSW",
            "params": {
            	"M": 10,
            	"efConstruction": 100
            }
        },
        {
            "fieldName": "title_embeddings",
            "metricType": "BM25",
            "indexName": "title_embeddings_index",
            "indexType": "SPARSE_INVERTED_INDEX",
            "params":{"inverted_index_algo": "DAAT_MAXSCORE"}
        }
    ]'

curl --request POST \
--url "${CLUSTER_ENDPOINT}/v2/vectordb/collections/create" \
--header "Authorization: Bearer ${TOKEN}" \
--header "Content-Type: application/json" \
-d "{
    \"collectionName\": \"creation\",
    \"schema\": $schema,
    \"indexParams\": $indexParams
}"

echo ""
echo "✓ Collection 'creation' created"
echo ""

# Create user collection
echo "2. Creating 'user' collection..."
export bm25Function='{
    "name": "username_bm25_emb",
    "type": "BM25",
    "inputFieldNames": ["username"],
    "outputFieldNames": ["username_embeddings"],
    "params": {}
}'
export schema='{
        "autoId": false,
        "enableDynamicField": true,
        "functions": ['"$bm25Function"'],
        "fields": [
            {
                "fieldName": "user_id",
                "dataType": "Int64",
                "isPrimary": true
            },
            {
                "fieldName": "username",
                "dataType": "VarChar",
                "elementTypeParams": {
                    "max_length": 200,
                    "enable_analyzer": true,
                    "enable_match": true
                }
            },
            {
                "fieldName": "username_embeddings",
                "dataType": "SparseFloatVector"
            },
            {
                "fieldName": "avatar",
                "dataType": "VarChar",
                "elementTypeParams": {
                    "max_length": 200
                }
            }
        ]
    }'
export indexParams='[
        {
            "fieldName": "user_id",
            "indexName": "user_id_index",
            "indexType": "AUTOINDEX"
        },
        {
            "fieldName": "username_embeddings",
            "metricType": "BM25",
            "indexName": "username_embeddings_index",
            "indexType": "SPARSE_INVERTED_INDEX",
            "params":{"inverted_index_algo": "DAAT_MAXSCORE"}
        }
    ]'

curl --request POST \
--url "${CLUSTER_ENDPOINT}/v2/vectordb/collections/create" \
--header "Authorization: Bearer ${TOKEN}" \
--header "Content-Type: application/json" \
-d "{
    \"collectionName\": \"user\",
    \"schema\": $schema,
    \"indexParams\": $indexParams
}"

echo ""
echo "✓ Collection 'user' created"
echo ""
echo "Done! All collections created successfully."