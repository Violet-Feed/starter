#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/violet-data-docker-compose.yaml}"
DATA_ROOT="${DATA_ROOT:-$HOME/violet/mnt}"

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
    log_info "Creating data directories for Violet data stack..."

    directories=(
        "$DATA_ROOT/postgresql/data"
        "$DATA_ROOT/juicefs-mount"

        "$DATA_ROOT/spark/spark-data"
        "$DATA_ROOT/spark/spark-events"
        "$DATA_ROOT/spark/spark-home"

        "$DATA_ROOT/airflow/logs"
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

    chmod -R 777 "$DATA_ROOT"

    log_success "Permissions updated: $DATA_ROOT"
}

validate_compose_file() {
    log_info "Validating compose file..."

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Cannot find compose file: $COMPOSE_FILE"
        log_error "You can specify it explicitly, for example:"
        echo "  COMPOSE_FILE=./your-compose.yaml $0"
        exit 1
    fi

    docker compose -f "$COMPOSE_FILE" config >/dev/null

    log_success "Compose file validation passed."
}

validate_config_files() {
    log_info "Validating config files used by docker-compose..."

    required_files=(
        "$SCRIPT_DIR/.config/juicefs/entrypoint.sh"

        "$SCRIPT_DIR/.config/hive/download-hive-libs.sh"
        "$SCRIPT_DIR/.config/hive/entry-metastore.sh"
        "$SCRIPT_DIR/.config/hive/entry-hiveserver2.sh"
        "$SCRIPT_DIR/.config/hive/core-site.xml"
        "$SCRIPT_DIR/.config/hive/hive-site.xml"

        "$SCRIPT_DIR/.config/spark/download-spark-libs.sh"
        "$SCRIPT_DIR/.config/spark/entry-spark.sh"
        "$SCRIPT_DIR/.config/spark/hive-site.xml"

        "$SCRIPT_DIR/.config/airflow/entrypoint.sh"
    )

    required_dirs=(
        "$SCRIPT_DIR/.config/postgres"
    )

    missing=0

    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log_error "Missing directory: $dir"
            missing=1
        else
            log_info "Found directory: $dir"
        fi
    done

    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Missing file: $file"
            missing=1
        else
            log_info "Found file: $file"
        fi
    done

    if [ "$missing" -ne 0 ]; then
        log_error "Please add the missing files or directories above before deployment."
        exit 1
    fi

    chmod +x "$SCRIPT_DIR/.config/juicefs/entrypoint.sh" || true

    chmod +x "$SCRIPT_DIR/.config/hive/download-hive-libs.sh" || true
    chmod +x "$SCRIPT_DIR/.config/hive/entry-metastore.sh" || true
    chmod +x "$SCRIPT_DIR/.config/hive/entry-hiveserver2.sh" || true

    chmod +x "$SCRIPT_DIR/.config/spark/download-spark-libs.sh" || true
    chmod +x "$SCRIPT_DIR/.config/spark/entry-spark.sh" || true

    chmod +x "$SCRIPT_DIR/.config/airflow/entrypoint.sh" || true

    log_success "Config file validation passed."
}

check_airflow_postgres_init() {
    log_info "Checking whether PostgreSQL init scripts seem to include Airflow database/user..."

    if grep -RqiE "airflow|airflow123" "$SCRIPT_DIR/.config/postgres" 2>/dev/null; then
        log_success "Airflow PostgreSQL init hint found in .config/postgres."
    else
        log_warning "No Airflow database/user initialization hint found in .config/postgres."
        log_warning "Airflow expects: postgresql+psycopg2://airflow:airflow123@postgres:5432/airflow"
        log_warning "Make sure PostgreSQL creates database 'airflow' and user 'airflow' before Airflow starts."
        log_warning "If PostgreSQL data already exists, new init SQL files will not run automatically."
    fi
}

check_docker_sock() {
    log_info "Checking Docker socket for Airflow..."

    if [ ! -S /var/run/docker.sock ]; then
        log_warning "/var/run/docker.sock does not exist or is not a socket."
        log_warning "Airflow mounts Docker socket, so Docker-based tasks may not work."
        return
    fi

    log_success "Docker socket found."
}

check_ports() {
    log_info "Checking host port availability..."

    ports=(
        5432
        9083
        10000
        10002
        7077
        8080
        8081
        8082
        8083
        4040
        18080
    )

    busy=0

    for port in "${ports[@]}"; do
        if command -v ss >/dev/null 2>&1; then
            if ss -ltn | awk '{print $4}' | grep -Eq "(:|\\.)${port}$"; then
                log_warning "Port may already be in use: $port"
                busy=1
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -ltn | awk '{print $4}' | grep -Eq "(:|\\.)${port}$"; then
                log_warning "Port may already be in use: $port"
                busy=1
            fi
        else
            log_warning "Neither ss nor netstat found; skipped port check."
            return
        fi
    done

    if [ "$busy" -eq 0 ]; then
        log_success "Port check passed."
    else
        log_warning "Some ports may be occupied. Docker Compose may fail if conflicts are real."
    fi
}

pull_images() {
    log_info "Pulling Docker images for Violet data stack..."

    images=(
        "postgres:15-alpine"
        "juicedata/mount:ce-v1.2.1"
        "apache/hive:3.1.3"
        "apache/spark:3.5.7-scala2.12-java11-python3-ubuntu"
        "flink:2.1.1-java21"
        "apache/airflow:2.10.4"
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
    log_info "Starting Violet data services..."

    (
        cd "$SCRIPT_DIR"
        docker compose -f "$COMPOSE_FILE" up -d
    )

    log_success "Services started."
}

wait_for_services() {
    log_info "Waiting 60s for initial health checks..."
    sleep 60

    docker compose -f "$COMPOSE_FILE" ps
}

show_access_info() {
    echo ""
    log_success "Violet data stack is ready."
    echo ""
    echo "PostgreSQL: localhost:5432"
    echo "Hive Metastore Thrift: localhost:9083"
    echo "HiveServer2 JDBC/Thrift: localhost:10000"
    echo "HiveServer2 Web UI: http://localhost:10002"
    echo "Spark Master: spark://localhost:7077"
    echo "Spark Master Web UI: http://localhost:8080"
    echo "Spark Worker Web UI: http://localhost:8081"
    echo "Spark Application UI: http://localhost:4040"
    echo "Spark History Server: http://localhost:18080"
    echo "Flink Web UI: http://localhost:8082"
    echo "Airflow Web UI: http://localhost:8083"
    echo ""
    echo "Data root:"
    echo "  $DATA_ROOT"
    echo ""
    echo "Useful commands:"
    echo "  docker compose -f $COMPOSE_FILE ps"
    echo "  docker compose -f $COMPOSE_FILE logs -f <service>"
    echo "  docker compose -f $COMPOSE_FILE logs -f airflow"
    echo "  docker compose -f $COMPOSE_FILE restart <service>"
    echo "  docker compose -f $COMPOSE_FILE down"
    echo ""
}

main() {
    log_info "Initializing Violet data environment..."
    echo ""

    check_docker
    create_directories
    relax_permissions
    validate_config_files
    check_airflow_postgres_init
    check_docker_sock
    validate_compose_file
    check_ports

    echo ""
    read -p "Pull Docker images now? (y/n) " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        pull_images
    else
        log_warning "Skipped image pull. Make sure images exist locally."
    fi

    echo ""
    read -p "Start services now? (y/n) " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
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