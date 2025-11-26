#!/bin/bash

set -e

# Create MySQL source connector
echo "Creating MySQL source connector..."
curl -sS -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d '{
  "name": "mysql-source",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "topic.prefix": "mysql",
    "database.hostname": "mysql",
    "database.port": "3306",
    "database.user": "debezium",
    "database.password": "123456",
    "database.include.list": "violet",
    "table.include.list": "violet.user,violet.creation",
    "database.server.id": "5401",
    "snapshot.mode": "initial",
    "include.schema.changes": "false",
    "decimal.handling.mode": "string",
    "time.precision.mode": "adaptive_time_microseconds",
    "tombstones.on.delete": "false",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "true",
    "schema.history.internal.kafka.bootstrap.servers": "kafka:9092",
    "schema.history.internal.kafka.topic": "schema-changes.mysql",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false"
  }
}'

echo -e "\n\nWaiting 5s..."
sleep 5

# Check MySQL source status
echo "Checking MySQL source connector status..."
curl -s http://localhost:8083/connectors/mysql-source/status | jq

# Create Milvus sink connector
echo "Creating Milvus sink connector..."
curl -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d '{
  "name": "milvus-sink-user",
  "config": {
    "connector.class": "com.milvus.io.kafka.MilvusSinkConnector",
    "public.endpoint": "http://milvus:19530",
    "token": "root:Milvus",
    "collection.name": "user",
    "topics": "mysql.violet.user"
  }
}'

echo -e "\n\nWaiting 5s..."
sleep 5

# Check Milvus sink status
echo "Checking Milvus sink connector status..."
curl -s http://localhost:8083/connectors/milvus-sink-user/status | jq

echo -e "\n\nDone!"