#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load MySQL schema into the running container
if docker ps --format '{{.Names}}' | Select-String -Quiet '^violet-mysql$'; then
    docker exec -i violet-mysql mysql -uroot -proot < "$SCRIPT_DIR/mysql/mysql.sql"
else
    echo "[ERROR] violet-mysql container is not running."
    exit 1
fi

echo "MySQL schema initialized."

# Run Nebula initialization script via console container
if docker ps --format '{{.Names}}' | Select-String -Quiet '^violet-nebula-console$'; then
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
bash "$SCRIPT_DIR/debezium/debezium.sh"

echo "Debezium connectors configured."
