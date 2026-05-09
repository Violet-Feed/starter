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

CORE_SERVICES=(
    redis
    kvrocks
    rmq-namesrv
    rmq-broker
    kafka
    connect
    mysql
    milvus
    metad0
    storaged0
    graphd
    storage-activator
)

OPTIONAL_SERVICES=(
    kafka-ui
    nebula-console
    nebula-studio
)

ALL_SERVICES=(
    "${CORE_SERVICES[@]}"
    "${OPTIONAL_SERVICES[@]}"
)

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

check_compose_file() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Cannot find compose file: $COMPOSE_FILE"
        exit 1
    fi
}

target_label() {
    local target="${1:-default}"

    case "$target" in
        ""|"default"|"core")
            echo "core services"
            ;;
        "all")
            echo "all services"
            ;;
        *)
            echo "service: $target"
            ;;
    esac
}

services_for_target() {
    local target="${1:-default}"

    case "$target" in
        ""|"default"|"core")
            printf '%s\n' "${CORE_SERVICES[@]}"
            ;;
        "all")
            printf '%s\n' "${ALL_SERVICES[@]}"
            ;;
        *)
            printf '%s\n' "$target"
            ;;
    esac
}

ask_yes_no() {
    local prompt="$1"

    read -p "$prompt (y/n) " -n 1 -r
    echo

    [[ "${REPLY:-}" =~ ^[Yy]$ ]]
}

create_directories() {
    log_info "Creating data directories..."

    directories=(
        "$DATA_ROOT/redis/data"
        "$DATA_ROOT/kvrocks"
        "$DATA_ROOT/rocketmq/store"
        "$DATA_ROOT/rocketmq/logs"
        "$DATA_ROOT/kafka/data"
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
    log_info "Setting permissive permissions for data directories..."

    mkdir -p "$DATA_ROOT"
    chmod -R 777 "$DATA_ROOT"

    log_success "Permissions updated: $DATA_ROOT"
}

validate_config_files() {
    log_info "Validating config files..."

    required_files=(
        "$SCRIPT_DIR/rocketmq/broker.conf"
        "$SCRIPT_DIR/kvrocks/kvrocks.conf"
        "$SCRIPT_DIR/milvus/embedEtcd.yaml"
        "$SCRIPT_DIR/milvus/user.yaml"
        "$SCRIPT_DIR/mysql/mysql.sql"
        "$SCRIPT_DIR/nebula/nebula.ngql"
    )

    missing=0

    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Missing: $file"
            missing=1
        else
            log_info "Found: $file"
        fi
    done

    if [ "$missing" -ne 0 ]; then
        log_error "Please add the missing files above before deployment."
        exit 1
    fi

    log_success "Config file validation passed."
}

copy_kvrocks_config() {
    log_info "Syncing kvrocks.conf to $DATA_ROOT/kvrocks ..."

    local src="$SCRIPT_DIR/kvrocks/kvrocks.conf"
    local dest_dir="$DATA_ROOT/kvrocks"
    local dest="$dest_dir/kvrocks.conf"

    if [ ! -f "$src" ]; then
        log_error "Missing kvrocks config: $src"
        exit 1
    fi

    mkdir -p "$dest_dir"

    cp "$src" "$dest"

    chmod 777 "$dest_dir"
    chmod 666 "$dest"

    log_success "kvrocks.conf copied to $dest"
}

prepare_runtime_layout() {
    log_info "Preparing runtime directories, config files and permissions..."

    create_directories
    validate_config_files
    copy_kvrocks_config
    relax_permissions

    log_success "Runtime layout is ready."
}

pull_images() {
    log_info "Pulling Docker images..."

    images=(
        "redis:5.0.14"
        "apache/kvrocks:2.13.0"
        "apache/rocketmq:5.2.0"
        "apache/kafka:4.0.0"
        "rootpublic/kafka-ui:0.7.2"
        "debezium/connect:2.7.3.Final"
        "mysql:8.0.35-bullseye"
        "milvusdb/milvus:v2.6.6"
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

compose_up_target() {
    local target="${1:-default}"
    local services=()

    mapfile -t services < <(services_for_target "$target")

    log_info "Starting $(target_label "$target")..."
    log_info "Services: ${services[*]}"

    (
        cd "$SCRIPT_DIR"
        docker compose -f "$COMPOSE_FILE" up -d "${services[@]}"
    )

    log_success "Started."
}

compose_restart_target() {
    local target="${1:-default}"
    local services=()

    mapfile -t services < <(services_for_target "$target")

    log_info "Restarting $(target_label "$target")..."
    log_info "Services: ${services[*]}"

    (
        cd "$SCRIPT_DIR"
        docker compose -f "$COMPOSE_FILE" restart "${services[@]}"
    )

    log_success "Restarted."
}

compose_redeploy_target() {
    local target="${1:-default}"
    local services=()

    mapfile -t services < <(services_for_target "$target")

    log_info "Redeploying $(target_label "$target")..."
    log_info "Services: ${services[*]}"

    (
        cd "$SCRIPT_DIR"
        docker compose -f "$COMPOSE_FILE" stop "${services[@]}" || true
        docker compose -f "$COMPOSE_FILE" rm -f "${services[@]}"
        docker compose -f "$COMPOSE_FILE" up -d "${services[@]}"
    )

    log_success "Redeployed."
}

compose_stop_target() {
    local target="${1:-default}"
    local services=()

    mapfile -t services < <(services_for_target "$target")

    log_info "Stopping $(target_label "$target")..."
    log_info "Services: ${services[*]}"

    (
        cd "$SCRIPT_DIR"
        docker compose -f "$COMPOSE_FILE" stop "${services[@]}"
    )

    log_success "Stopped."
}

compose_logs_target() {
    local target="${1:-default}"
    local services=()

    mapfile -t services < <(services_for_target "$target")

    log_info "Tailing logs for $(target_label "$target")..."
    log_info "Services: ${services[*]}"

    (
        cd "$SCRIPT_DIR"
        docker compose -f "$COMPOSE_FILE" logs -f "${services[@]}"
    )
}

deploy_services() {
    local target="${2:-default}"

    log_info "Initializing Violet environment for $(target_label "$target")..."
    echo ""

    check_docker
    check_compose_file
    prepare_runtime_layout

    if ask_yes_no "Pull Docker images now?"; then
        pull_images
    else
        log_warning "Skipped image pull. Make sure images exist locally."
    fi

    echo ""

    if ask_yes_no "Start $(target_label "$target") now?"; then
        compose_up_target "$target"
        wait_for_services
        show_access_info
    else
        log_info "Services not started. Run one of these later:"
        echo "  bash $0 start"
        echo "  bash $0 start all"
        echo "  bash $0 start kafka-ui"
    fi

    log_success "Setup finished."
}

start_services() {
    local target="${2:-default}"

    check_docker
    check_compose_file
    prepare_runtime_layout

    compose_up_target "$target"
}

restart_services() {
    local target="${2:-default}"

    check_docker
    check_compose_file
    prepare_runtime_layout

    compose_restart_target "$target"
}

redeploy_services() {
    local target="${2:-default}"

    check_docker
    check_compose_file
    prepare_runtime_layout

    compose_redeploy_target "$target"
}

stop_services() {
    local target="${2:-default}"

    check_docker
    check_compose_file

    compose_stop_target "$target"
}

logs_services() {
    local target="${2:-default}"

    check_docker
    check_compose_file

    compose_logs_target "$target"
}

wait_for_services() {
    log_info "Waiting 30s for health checks..."
    sleep 30

    (
        cd "$SCRIPT_DIR"
        docker compose -f "$COMPOSE_FILE" ps
    )
}

show_access_info() {
    echo ""
    log_success "Violet stack is ready."
    echo ""
    echo "--- Infrastructure ---"
    echo "Redis: localhost:6379"
    echo "Kvrocks: localhost:6666"
    echo "RocketMQ NameServer: localhost:9876"
    echo "RocketMQ Broker: localhost:10911"
    echo "Kafka for same Docker network: kafka:9092"
    echo "Kafka for remote clients/Spark: 8.130.134.60:9094"
    echo "Kafka UI: http://localhost:8080"
    echo "Kafka Connect / Debezium: http://localhost:8083"
    echo "MySQL: localhost:3306 (root/root)"
    echo "Milvus: localhost:19530"
    echo "Nebula Graph: localhost:9669 (root/nebula)"
    echo "Nebula Studio: http://localhost:7001"
    echo ""
    echo "--- Backend Services ---"
    echo "Gateway HTTP:  http://localhost:3000"
    echo "Gateway TCP:   localhost:3001"
    echo "Gateway gRPC:  localhost:3002"
    echo "Action gRPC:   localhost:3003"
    echo "IM gRPC:       localhost:3004"
    echo "AIGC gRPC:     localhost:3005"
    echo ""
    echo "--- Service groups ---"
    echo "Default target: core services"
    echo "All target: core services + kafka-ui + nebula-console + nebula-studio"
    echo ""
    echo "Useful commands:"
    echo "  bash $0 deploy              # Prepare env, optionally start core services"
    echo "  bash $0 deploy all          # Prepare env, optionally start all services"
    echo "  bash $0 start               # Start core services"
    echo "  bash $0 start all           # Start all services"
    echo "  bash $0 start kafka-ui      # Start one optional service"
    echo "  bash $0 restart             # Restart core services"
    echo "  bash $0 restart all         # Restart all services"
    echo "  bash $0 redeploy            # Redeploy core services"
    echo "  bash $0 redeploy all        # Redeploy all services"
    echo "  bash $0 logs                # Tail core service logs"
    echo "  bash $0 logs all            # Tail all service logs"
    echo ""
}

show_help() {
    echo "Usage: $0 <command> [target]"
    echo ""
    echo "Targets:"
    echo "  default/core    Core services only"
    echo "  all             Core services + optional UI services"
    echo "  <service>       A single compose service, such as kafka-ui or nebula-studio"
    echo ""
    echo "Core services:"
    echo "  ${CORE_SERVICES[*]}"
    echo ""
    echo "Optional services:"
    echo "  ${OPTIONAL_SERVICES[*]}"
    echo ""
    echo "Commands:"
    echo "  deploy      Prepare runtime layout, optionally pull images, optionally start target"
    echo "  start       Start target"
    echo "  stop        Stop target"
    echo "  restart     Restart target"
    echo "  redeploy    Stop, remove, and re-create target"
    echo "  logs        Tail target logs"
    echo "  help        Show help"
    echo ""
    echo "Examples:"
    echo "  bash $0 deploy"
    echo "  bash $0 deploy all"
    echo "  bash $0 start"
    echo "  bash $0 start all"
    echo "  bash $0 start kafka-ui"
    echo "  bash $0 restart"
    echo "  bash $0 restart all"
    echo "  bash $0 redeploy"
    echo "  bash $0 redeploy all"
    echo "  bash $0 redeploy kvrocks"
    echo "  bash $0 logs kafka"
    echo "  bash $0 logs all"
}

main() {
    local cmd="${1:-deploy}"

    case "$cmd" in
        deploy)
            deploy_services "$@"
            ;;
        start)
            start_services "$@"
            wait_for_services
            ;;
        stop)
            stop_services "$@"
            ;;
        restart)
            restart_services "$@"
            wait_for_services
            ;;
        redeploy)
            redeploy_services "$@"
            wait_for_services
            ;;
        logs)
            logs_services "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"