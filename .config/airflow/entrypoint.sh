#!/bin/bash
set -e

REPO_DIR="/opt/swing-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/swing.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"

echo "Installing docker CLI and git..."
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq docker.io git > /dev/null 2>&1
rm -rf /var/lib/apt/lists/*

echo "Cloning repo: ${GIT_REPO} (branch: ${GIT_BRANCH})"
rm -rf "${REPO_DIR}"
git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${REPO_DIR}"

echo "Syncing DAGs..."
rsync -a --delete "${REPO_DIR}/airflow/dags/" /opt/airflow/dags/

echo "Initializing Airflow..."
airflow db migrate
airflow users create \
    --username admin \
    --password admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com 2>/dev/null || true

echo "Starting Airflow webserver & scheduler..."
airflow webserver &
exec airflow scheduler