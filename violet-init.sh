#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load MySQL schema into the running container
if docker ps --format '{{.Names}}' | grep -q '^violet-mysql$'; then
    docker exec -i violet-mysql mysql -uroot -proot < "$SCRIPT_DIR/mysql/mysql.sql"
else
    echo "[ERROR] violet-mysql container is not running."
    exit 1
fi

echo "MySQL schema initialized."

# Run Nebula initialization script via console container
if docker ps --format '{{.Names}}' | grep -q '^violet-nebula-console$'; then
    docker exec -i violet-nebula-console nebula-console -addr graphd -port 9669 -u root -p nebula -f /violet/nebula.ngql
else
    echo "[ERROR] violet-nebula-console container is not running."
    exit 1
fi

echo "Nebula script executed."

# Milvus collection setup
bash "$SCRIPT_DIR/milvus/milvus.sh"

echo "Milvus collections created."

# Debezium connectors
docker cp "$SCRIPT_DIR/debezium/connectors/zilliz-kafka-connect-milvus-1.0.0/" violet-kafka-connect:/kafka/connect/
echo "Restarting Kafka Connect container..."
docker restart violet-kafka-connect
echo "Kafka Connect restarted."
bash "$SCRIPT_DIR/debezium/debezium.sh"

echo "Debezium connectors configured."
