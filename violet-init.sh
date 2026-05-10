#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

container_running() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -q "^${name}$"
}

# MySQL schema
init_mysql() {
    log_info "Initializing MySQL schema..."

    if ! container_running "violet-mysql"; then
        log_error "violet-mysql container is not running."
        exit 1
    fi

    if [ ! -f "$SCRIPT_DIR/mysql/mysql.sql" ]; then
        log_error "Missing MySQL schema file: $SCRIPT_DIR/mysql/mysql.sql"
        exit 1
    fi

    set +e
    docker exec -i violet-mysql mysql \
        -uroot \
        -proot \
        --default-character-set=utf8mb4 \
        --force \
        < "$SCRIPT_DIR/mysql/mysql.sql"
    mysql_code=$?
    set -e

    if [ "$mysql_code" -ne 0 ]; then
        log_warning "MySQL schema execution finished with warnings/errors. Existing tables may have been skipped."
    else
        log_success "MySQL schema initialized."
    fi
}

# Nebula initialization
init_nebula() {
    log_info "Initializing Nebula..."

    if ! container_running "violet-nebula-console"; then
        log_warning "violet-nebula-console container is not running. Skipping Nebula initialization."
        return 0
    fi

    if [ ! -f "$SCRIPT_DIR/nebula/nebula.ngql" ]; then
        log_error "Missing Nebula script: $SCRIPT_DIR/nebula/nebula.ngql"
        exit 1
    fi

    docker exec -i violet-nebula-console \
        nebula-console \
        -addr graphd \
        -port 9669 \
        -u root \
        -p nebula \
        -f /violet/nebula.ngql

    log_success "Nebula script executed."
}

# Milvus collection setup
init_milvus() {
    log_info "Initializing Milvus..."

    if [ ! -f "$SCRIPT_DIR/milvus/milvus.sh" ]; then
        log_warning "Missing Milvus init script: $SCRIPT_DIR/milvus/milvus.sh. Skipping Milvus initialization."
        return 0
    fi

    bash "$SCRIPT_DIR/milvus/milvus.sh"

    log_success "Milvus collections created."
}

# Debezium connectors
init_debezium() {
    log_info "Initializing Debezium connectors..."

    if [ ! -f "$SCRIPT_DIR/debezium/debezium.sh" ]; then
        log_warning "Missing Debezium init script: $SCRIPT_DIR/debezium/debezium.sh. Skipping Debezium initialization."
        return 0
    fi

    bash "$SCRIPT_DIR/debezium/debezium.sh"

    log_success "Debezium connectors configured."
}

# RocketMQ topics
init_rocketmq() {
    log_info "Initializing RocketMQ topics..."

    if ! container_running "violet-rmq-broker"; then
        log_error "violet-rmq-broker container is not running."
        exit 1
    fi

    docker exec -i violet-rmq-broker sh -lc '
        sh mqadmin updateTopic -n rmq-namesrv:9876 -t im_conv -c DefaultCluster
        sh mqadmin updateTopic -n rmq-namesrv:9876 -t im_user -c DefaultCluster
    '

    log_success "RocketMQ topics created."
}

init_mysql
init_nebula
init_milvus
init_debezium
init_rocketmq

log_success "Violet initialization finished."