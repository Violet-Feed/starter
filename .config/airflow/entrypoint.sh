#!/bin/bash
set -Eeuo pipefail

REPO_DIR="/opt/swing-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/swing.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"
DAGS_DIR="/opt/airflow/dags"

echo "Installing required tools..."

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    rsync \
    curl \
    ca-certificates

rm -rf /var/lib/apt/lists/*

echo "Tool versions:"
git --version
rsync --version | head -1 || true

if command -v docker >/dev/null 2>&1; then
    docker --version || true
else
    echo "WARNING: docker CLI not found in container."
    echo "Docker-based Airflow tasks may not work unless docker CLI is installed in the image."
fi

if [ -S /var/run/docker.sock ]; then
    echo "Docker socket found: /var/run/docker.sock"
else
    echo "WARNING: /var/run/docker.sock not found. Docker-based Airflow tasks may not work."
fi

echo "Cloning repo: ${GIT_REPO} branch ${GIT_BRANCH}"
rm -rf "${REPO_DIR}"
git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${REPO_DIR}"

echo "Syncing DAGs..."
mkdir -p "${DAGS_DIR}"

if [ -d "${REPO_DIR}/airflow/dags" ]; then
    rsync -a --delete "${REPO_DIR}/airflow/dags/" "${DAGS_DIR}/"
else
    echo "ERROR: DAG source directory does not exist: ${REPO_DIR}/airflow/dags"
    exit 1
fi

echo "Initializing Airflow metadata database..."
airflow db migrate

echo "Creating Airflow admin user if needed..."
airflow users create \
    --username admin \
    --password admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    || true

echo "Starting Airflow webserver and scheduler..."
airflow webserver &

exec airflow scheduler