#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/swing-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/swing.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"

if ! command -v git > /dev/null 2>&1; then
    echo "git not found, installing git..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git \
        ca-certificates
    rm -rf /var/lib/apt/lists/*
fi

echo "Syncing ETL scripts from ${GIT_REPO} (branch: ${GIT_BRANCH})..."
rm -rf "${REPO_DIR}"

git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${REPO_DIR}"

if [ -d "${REPO_DIR}/etl" ]; then
    rm -rf /opt/spark-apps/*
    cp -r "${REPO_DIR}"/etl/* /opt/spark-apps/
    echo "ETL scripts synced to /opt/spark-apps/"
else
    echo "ERROR: ETL directory not found: ${REPO_DIR}/etl"
    exit 1
fi

# 下载 Spark 依赖并启动 master/worker/history
/opt/spark/download-spark-libs.sh /opt/spark/jars

mkdir -p /tmp/spark-events
mkdir -p /home/spark
mkdir -p /home/spark/.ivy2/cache
chown -R spark:spark /home/spark /tmp/spark-events 2>/dev/null || true

/opt/spark/bin/spark-class org.apache.spark.deploy.master.Master &
/opt/spark/bin/spark-class org.apache.spark.deploy.worker.Worker spark://spark:7077 &
/opt/spark/bin/spark-class org.apache.spark.deploy.history.HistoryServer &

wait