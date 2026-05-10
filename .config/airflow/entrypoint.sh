#!/bin/bash
set -Eeuo pipefail

REPO_DIR="/opt/swing-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/swing.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"
DAGS_DIR="/opt/airflow/dags"

AIRFLOW_INIT_DB="${AIRFLOW_INIT_DB:-true}"
AIRFLOW_CREATE_ADMIN="${AIRFLOW_CREATE_ADMIN:-true}"

APT_MIRROR="${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
APT_SECURITY_MIRROR="${APT_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"

INSTALL_DOCKER_CLI="${INSTALL_DOCKER_CLI:-false}"

setup_apt_mirror() {
    if [ ! -f /etc/os-release ]; then
        echo "WARNING: /etc/os-release not found, skip apt mirror setup."
        return 0
    fi

    . /etc/os-release

    local codename="${VERSION_CODENAME:-bookworm}"

    echo "Using APT mirror: ${APT_MIRROR}"
    echo "Using APT security mirror: ${APT_SECURITY_MIRROR}"
    echo "Debian codename: ${codename}"

    rm -f /etc/apt/sources.list.d/debian.sources || true

    cat > /etc/apt/sources.list <<EOF
deb ${APT_MIRROR} ${codename} main contrib non-free non-free-firmware
deb ${APT_MIRROR} ${codename}-updates main contrib non-free non-free-firmware
deb ${APT_SECURITY_MIRROR} ${codename}-security main contrib non-free non-free-firmware
EOF
}

install_missing_tools() {
    local missing=()

    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v rsync >/dev/null 2>&1 || missing+=("rsync")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

    if [ "${INSTALL_DOCKER_CLI}" = "true" ]; then
        command -v docker >/dev/null 2>&1 || missing+=("docker.io")
    fi

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "Required tools already installed."
        return 0
    fi

    setup_apt_mirror

    echo "Installing missing tools: ${missing[*]}"

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        "${missing[@]}" \
        ca-certificates

    rm -rf /var/lib/apt/lists/*
}

check_docker_access() {
    if command -v docker >/dev/null 2>&1; then
        docker --version || true
    else
        echo "WARNING: docker CLI not found in container."
        echo "Docker-based Airflow tasks may not work unless docker CLI is baked into the image."
        echo "Set INSTALL_DOCKER_CLI=true if you really want to install docker.io at container startup."
    fi

    if [ -S /var/run/docker.sock ]; then
        echo "Docker socket found: /var/run/docker.sock"
    else
        echo "WARNING: /var/run/docker.sock not found. Docker-based Airflow tasks may not work."
    fi
}

sync_repo() {
    echo "Syncing repo: ${GIT_REPO} branch ${GIT_BRANCH}"

    if [ -d "${REPO_DIR}/.git" ]; then
        cd "${REPO_DIR}"
        git remote set-url origin "${GIT_REPO}" || true
        git fetch --depth 1 origin "${GIT_BRANCH}"
        git checkout -B "${GIT_BRANCH}" "origin/${GIT_BRANCH}"
        git reset --hard "origin/${GIT_BRANCH}"
    else
        rm -rf "${REPO_DIR}"
        git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${REPO_DIR}"
    fi
}

sync_dags() {
    echo "Syncing DAGs..."

    if [ ! -d "${REPO_DIR}/airflow/dags" ]; then
        echo "ERROR: DAG source directory does not exist: ${REPO_DIR}/airflow/dags"
        exit 1
    fi

    mkdir -p "${DAGS_DIR}"
    rsync -a --delete "${REPO_DIR}/airflow/dags/" "${DAGS_DIR}/"

    echo "DAGs synced to ${DAGS_DIR}"
}

init_airflow() {
    if [ "${AIRFLOW_INIT_DB}" = "true" ]; then
        echo "Migrating Airflow metadata database..."
        airflow db migrate
    else
        echo "Skipping Airflow db migrate because AIRFLOW_INIT_DB=${AIRFLOW_INIT_DB}"
    fi

    if [ "${AIRFLOW_CREATE_ADMIN}" = "true" ]; then
        echo "Creating Airflow admin user if needed..."

        airflow users create \
            --username admin \
            --password admin \
            --firstname Admin \
            --lastname User \
            --role Admin \
            --email admin@example.com \
            || true
    else
        echo "Skipping Airflow admin user creation because AIRFLOW_CREATE_ADMIN=${AIRFLOW_CREATE_ADMIN}"
    fi
}

start_airflow() {
    echo "Starting Airflow webserver and scheduler..."

    airflow webserver &

    exec airflow scheduler
}

install_missing_tools
check_docker_access
sync_repo
sync_dags
init_airflow
start_airflow