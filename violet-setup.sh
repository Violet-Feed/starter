#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/repos"

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

clone_repos() {
    log_info "Cloning Violet-Feed backend repositories..."

    mkdir -p "$REPOS_DIR"

    repos=("gateway" "action" "aigc" "im" "chatbot")

    for repo in "${repos[@]}"; do
        if [ -d "$REPOS_DIR/$repo" ]; then
            log_info "Pulling latest changes for $repo..."
            (cd "$REPOS_DIR/$repo" && git pull)
        else
            log_info "Cloning $repo..."
            git clone "https://github.com/Violet-Feed/$repo.git" "$REPOS_DIR/$repo"
        fi
    done

    log_success "All repositories ready."
}

prepare_aigc_ffmpeg() {
    log_info "Preparing static ffmpeg for aigc..."

    local aigc_dir="$REPOS_DIR/aigc"
    local bin_dir="$aigc_dir/bin"
    local tmp_dir="/tmp/violet-ffmpeg-static"
    local arch
    local github_asset_url
    local mirror_url
    local proxy_prefix="https://gh-proxy.com/"

    if [ ! -d "$aigc_dir" ]; then
        log_error "AIGC repository not found: $aigc_dir"
        log_error "Run '$0 clone' or '$0 setup' first."
        exit 1
    fi

    mkdir -p "$bin_dir"

    if [ -x "$bin_dir/ffmpeg" ] && [ -x "$bin_dir/ffprobe" ]; then
        if timeout 10s "$bin_dir/ffmpeg" -version >/dev/null 2>&1 && \
           timeout 10s "$bin_dir/ffprobe" -version >/dev/null 2>&1; then
            log_success "Static ffmpeg already exists and works."
            return 0
        fi

        log_warning "Existing ffmpeg is not usable. Re-downloading..."
        rm -f "$bin_dir/ffmpeg" "$bin_dir/ffprobe"
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to download ffmpeg."
        exit 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        log_error "tar is required to extract ffmpeg."
        exit 1
    fi

    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64)
            github_asset_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
            ;;
        aarch64|arm64)
            github_asset_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    mirror_url="${proxy_prefix}${github_asset_url}"

    log_info "Architecture: $arch"
    log_info "Using public GitHub mirror:"
    log_info "$mirror_url"

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    curl -L \
        --retry 10 \
        --retry-delay 5 \
        --connect-timeout 20 \
        --max-time 3600 \
        -o "$tmp_dir/ffmpeg-static.tar.xz" \
        "$mirror_url"

    log_info "Extracting ffmpeg..."

    tar -xJf "$tmp_dir/ffmpeg-static.tar.xz" \
        -C "$tmp_dir"

    local ffmpeg_bin
    local ffprobe_bin

    ffmpeg_bin="$(find "$tmp_dir" -type f -name ffmpeg | head -1 || true)"
    ffprobe_bin="$(find "$tmp_dir" -type f -name ffprobe | head -1 || true)"

    if [ -z "$ffmpeg_bin" ] || [ ! -f "$ffmpeg_bin" ]; then
        log_error "ffmpeg binary not found after extraction."
        exit 1
    fi

    if [ -z "$ffprobe_bin" ] || [ ! -f "$ffprobe_bin" ]; then
        log_error "ffprobe binary not found after extraction."
        exit 1
    fi

    cp "$ffmpeg_bin" "$bin_dir/ffmpeg"
    cp "$ffprobe_bin" "$bin_dir/ffprobe"

    chmod +x "$bin_dir/ffmpeg" "$bin_dir/ffprobe"

    log_info "Testing static ffmpeg..."

    timeout 10s "$bin_dir/ffmpeg" -version >/dev/null
    timeout 10s "$bin_dir/ffprobe" -version >/dev/null

    rm -rf "$tmp_dir"

    log_success "Static ffmpeg prepared:"
    echo "  $bin_dir/ffmpeg"
    echo "  $bin_dir/ffprobe"
}

copy_dockerfiles() {
    log_info "Copying Dockerfiles into repository directories..."

    cp "$SCRIPT_DIR/docker/gateway/Dockerfile" "$REPOS_DIR/gateway/Dockerfile"
    cp "$SCRIPT_DIR/docker/action/Dockerfile" "$REPOS_DIR/action/Dockerfile"
    cp "$SCRIPT_DIR/docker/aigc/Dockerfile" "$REPOS_DIR/aigc/Dockerfile"
    cp "$SCRIPT_DIR/docker/im/Dockerfile" "$REPOS_DIR/im/Dockerfile"
    cp "$SCRIPT_DIR/docker/chatbot/Dockerfile" "$REPOS_DIR/chatbot/Dockerfile"

    repos=("gateway" "action" "aigc" "im" "chatbot")
    for repo in "${repos[@]}"; do
        if ! grep -q "Dockerfile" "$REPOS_DIR/$repo/.git/info/exclude" 2>/dev/null; then
            echo "Dockerfile" >> "$REPOS_DIR/$repo/.git/info/exclude"
        fi

        if [ "$repo" = "aigc" ]; then
            if ! grep -q "^bin/ffmpeg$" "$REPOS_DIR/$repo/.git/info/exclude" 2>/dev/null; then
                echo "bin/ffmpeg" >> "$REPOS_DIR/$repo/.git/info/exclude"
            fi

            if ! grep -q "^bin/ffprobe$" "$REPOS_DIR/$repo/.git/info/exclude" 2>/dev/null; then
                echo "bin/ffprobe" >> "$REPOS_DIR/$repo/.git/info/exclude"
            fi
        fi
    done

    log_success "Dockerfiles copied and excluded from git tracking."
}

check_dockerfiles() {
    log_info "Verifying Dockerfiles exist in repos..."

    repos=("gateway" "action" "aigc" "im" "chatbot")
    missing=0
    for repo in "${repos[@]}"; do
        if [ ! -f "$REPOS_DIR/$repo/Dockerfile" ]; then
            log_error "Missing: $REPOS_DIR/$repo/Dockerfile"
            missing=1
        else
            log_info "Found: $REPOS_DIR/$repo/Dockerfile"
        fi
    done

    if [ "$missing" -ne 0 ]; then
        log_error "Some Dockerfiles are missing. Run copy_dockerfiles first."
        exit 1
    fi

    log_success "All Dockerfiles verified."
}

check_repo_readiness() {
    log_info "Checking repository structure..."

    java_repos=("gateway" "action" "aigc")
    for repo in "${java_repos[@]}"; do
        if [ ! -f "$REPOS_DIR/$repo/pom.xml" ]; then
            log_error "$repo: pom.xml not found at repo root"
            log_error "If your pom.xml is in a subdirectory, adjust the Dockerfile build context."
            exit 1
        fi
        log_info "$repo: pom.xml OK"
    done

    if [ ! -f "$REPOS_DIR/aigc/bin/ffmpeg" ]; then
        log_error "aigc: missing static ffmpeg at $REPOS_DIR/aigc/bin/ffmpeg"
        log_error "Run '$0 ffmpeg' first."
        exit 1
    fi

    if [ ! -f "$REPOS_DIR/aigc/bin/ffprobe" ]; then
        log_error "aigc: missing static ffprobe at $REPOS_DIR/aigc/bin/ffprobe"
        log_error "Run '$0 ffmpeg' first."
        exit 1
    fi

    log_info "aigc: static ffmpeg OK"

    if [ ! -f "$REPOS_DIR/im/go.mod" ]; then
        log_error "im: go.mod not found at repo root"
        exit 1
    fi
    log_info "im: go.mod OK"

    if [ ! -f "$REPOS_DIR/chatbot/pyproject.toml" ]; then
        log_error "chatbot: pyproject.toml not found at repo root"
        exit 1
    fi
    log_info "chatbot: pyproject.toml OK"

    log_success "Repository structure check passed."
}

build_images() {
    log_info "Building Docker images (this may take a while)..."

    prepare_aigc_ffmpeg

    (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml build gateway)
    log_success "gateway image built."

    (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml build action)
    log_success "action image built."

    (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml build aigc)
    log_success "aigc image built."

    (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml build im)
    log_success "im image built."

    (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml build chatbot)
    log_success "chatbot image built."

    log_success "All images built."
}

start_backend() {
    log_info "Starting backend services..."

    (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml up -d gateway action aigc im chatbot)

    log_success "Backend services started."
    echo ""
    echo "  Gateway HTTP:   http://localhost:3000"
    echo "  Gateway TCP:    localhost:3001"
    echo "  Gateway gRPC:   localhost:3002"
    echo "  Action gRPC:    localhost:3003"
    echo "  IM gRPC:        localhost:3004"
    echo "  AIGC gRPC:      localhost:3005"
    echo ""
}

stop_backend() {
    local svc="${1:-}"
    if [ -n "$svc" ]; then
        log_info "Stopping $svc..."
        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml stop "$svc")
    else
        log_info "Stopping all backend services..."
        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml stop gateway action aigc im chatbot)
    fi
    log_success "Stopped."
}

restart_backend() {
    local svc="${1:-}"
    if [ -n "$svc" ]; then
        log_info "Restarting $svc..."
        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml restart "$svc")
    else
        log_info "Restarting all backend services..."
        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml restart gateway action aigc im chatbot)
    fi
    log_success "Restarted."
}

logs_backend() {
    local svc="${1:-}"
    if [ -n "$svc" ]; then
        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml logs -f "$svc")
    else
        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml logs -f gateway action aigc im chatbot)
    fi
}

rebuild_backend() {
    local svc="${1:-}"
    if [ -n "$svc" ]; then
        log_info "Rebuilding $svc..."

        if [ "$svc" = "aigc" ]; then
            prepare_aigc_ffmpeg
        fi

        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml build --no-cache "$svc" && docker compose -f violet-docker-compose.yaml up -d "$svc")
    else
        log_info "Rebuilding all backend services..."

        prepare_aigc_ffmpeg

        (cd "$SCRIPT_DIR" && docker compose -f violet-docker-compose.yaml build --no-cache gateway action aigc im chatbot && docker compose -f violet-docker-compose.yaml up -d gateway action aigc im chatbot)
    fi
    log_success "Rebuilt and restarted."
}

show_help() {
    echo "Usage: $0 <command> [service]"
    echo ""
    echo "Commands:"
    echo "  clone     Clone or update all Violet-Feed backend repos"
    echo "  setup     Clone repos + copy Dockerfiles + prepare ffmpeg + check readiness"
    echo "  ffmpeg    Download static ffmpeg into repos/aigc/bin"
    echo "  build     Build all backend Docker images"
    echo "  start     Start backend services"
    echo "  stop      Stop backend services [service]"
    echo "  restart   Restart backend services [service]"
    echo "  logs      Tail logs of backend services [service]"
    echo "  rebuild   Rebuild (no-cache) and restart [service]"
    echo "  all       Full setup: clone -> copy -> prepare ffmpeg -> check -> build -> start"
    echo ""
    echo "Service names: gateway, action, aigc, im, chatbot"
    echo "Omit [service] to target all backend services."
}

main() {
    local cmd="${1:-all}"
    local svc="${2:-}"

    case "$cmd" in
        clone)
            clone_repos
            ;;
        setup)
            clone_repos
            copy_dockerfiles
            prepare_aigc_ffmpeg
            check_repo_readiness
            log_success "Setup complete. Run '$0 build' to build images."
            ;;
        ffmpeg)
            prepare_aigc_ffmpeg
            ;;
        build)
            check_dockerfiles
            prepare_aigc_ffmpeg
            check_repo_readiness
            build_images
            ;;
        start)
            start_backend
            ;;
        stop)
            stop_backend "$svc"
            ;;
        restart)
            restart_backend "$svc"
            ;;
        logs)
            logs_backend "$svc"
            ;;
        rebuild)
            rebuild_backend "$svc"
            ;;
        all)
            clone_repos
            copy_dockerfiles
            prepare_aigc_ffmpeg
            check_repo_readiness
            build_images
            echo ""
            read -p "Start backend services now? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                start_backend
            else
                log_info "Run '$0 start' to start backend services later."
            fi
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