#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/violet-docker-compose.yaml"
DATA_ROOT="$HOME/violet/mnt"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_docker() {
    log_info "Checking Docker environment..."

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed."
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose v2 is required."
        exit 1
    fi

    log_success "Docker check passed."
}

create_directories() {
    log_info "Creating data directories (matching docker-compose mounts)..."

    directories=(
        "$DATA_ROOT/redis/data"
        "$DATA_ROOT/kvrocks"
        "$DATA_ROOT/mysql/data"
        "$DATA_ROOT/milvus/data"
        "$DATA_ROOT/nebula/data/meta0"
        "$DATA_ROOT/nebula/data/storage0"
        "$DATA_ROOT/nebula/logs/meta0"
        "$DATA_ROOT/nebula/logs/storage0"
        "$DATA_ROOT/nebula/logs/graph"
    )

    for dir in "${directories[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            log_success "Created: $dir"
        else
            log_info "Exists: $dir"
        fi
    done

}

relax_permissions() {
    log_info "Setting permissive permissions for data directories (777)..."
    chmod -R 777 "$DATA_ROOT"
    log_success "Permissions updated: $DATA_ROOT"
}

validate_config_files() {
    log_info "Validating config files (used directly by docker-compose)..."

    required_files=(
        "$SCRIPT_DIR/milvus/embedEtcd.yaml"
        "$SCRIPT_DIR/milvus/user.yaml"
        "$SCRIPT_DIR/mysql/mysql.sql"
        "$SCRIPT_DIR/nebula/nebula.ngql"
        "$SCRIPT_DIR/kvrocks/kvrocks.conf"
    )

    missing=0
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Missing: $file"
            missing=1
        fi
    done

    if [ $missing -ne 0 ]; then
        log_error "Please add the missing files above; compose mounts them directly."
        exit 1
    fi
}

copy_kvrocks_config() {
    log_info "Syncing kvrocks.conf to $DATA_ROOT/kvrocks ..."

    local src="$SCRIPT_DIR/kvrocks/kvrocks.conf"
    local dest="$DATA_ROOT/kvrocks/kvrocks.conf"

    if [ ! -f "$src" ]; then
        log_error "kvrocks config not found: $src"
        exit 1
    fi

    cp "$src" "$dest"
    log_success "kvrocks.conf copied to $dest"
}

pull_images() {
    log_info "Pulling Docker images (may take a while)..."

    images=(
        "redis:5.0.14"
        "apache/kvrocks:2.13.0"
        "apache/kafka:4.0.0"
        "debezium/connect:2.7.3.Final"
        "mysql:8.0.35-bullseye"
        "milvusdb/milvus:v2.6.4"
        "vesoft/nebula-metad:v3.8.0"
        "vesoft/nebula-storaged:v3.8.0"
        "vesoft/nebula-graphd:v3.8.0"
        "vesoft/nebula-console:v3.8.0"
        "vesoft/nebula-graph-studio:v3.10.0"
    )

    for image in "${images[@]}"; do
        log_info "Pulling: $image"
        if docker pull "$image"; then
            log_success "Pulled: $image"
        else
            log_error "Failed to pull: $image"
            exit 1
        fi
    done

    log_success "All images pulled."
}

start_services() {
    log_info "Starting Violet services..."

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Cannot find compose file: $COMPOSE_FILE"
        exit 1
    fi

    (cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" up -d)
    log_success "Services started."
}

wait_for_services() {
    log_info "Waiting 30s for health checks..."
    sleep 30
    docker compose -f "$COMPOSE_FILE" ps
}

show_access_info() {
    echo ""
    log_success "Violet stack is ready."
    echo ""
    echo "Redis: localhost:6379"
    echo "Kvrocks: localhost:6666"
    echo "Kafka (internal): localhost:9092"
    echo "Kafka (external): localhost:9094"
    echo "Kafka Connect: http://localhost:8083"
    echo "MySQL: localhost:3306 (root/root)"
    echo "Milvus: localhost:19530"
    echo "Nebula Graph: localhost:9669 (root/nebula)"
    echo "Nebula Studio: http://localhost:7001"
    echo ""
    echo "Useful commands:"
    echo "  docker compose -f $COMPOSE_FILE ps"
    echo "  docker compose -f $COMPOSE_FILE logs -f <service>"
    echo "  docker compose -f $COMPOSE_FILE down"
    echo "  docker compose -f $COMPOSE_FILE restart <service>"
    echo ""
}

main() {
    log_info "Initializing Violet environment..."
    echo ""

    check_docker
    create_directories
    relax_permissions
    validate_config_files
    copy_kvrocks_config

    read -p "Pull Docker images now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pull_images
    else
        log_warning "Skipped image pull. Make sure images exist locally."
    fi

    echo ""
    read -p "Start services now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        start_services
        wait_for_services
        show_access_info
    else
        log_info "Services not started. Run manually with:"
        echo "  cd $SCRIPT_DIR && docker compose -f $COMPOSE_FILE up -d"
    fi

    log_success "Setup finished."
}

main "$@"
