#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/trend-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/trend.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"
JAR_DIR="/opt/flink/usrlib"
SUBMIT_INTERVAL="${FLINK_SUBMIT_INTERVAL:-300}"

echo "Installing Maven and Python3..."
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq maven python3 > /dev/null 2>&1
rm -rf /var/lib/apt/lists/*

echo "Cloning trend: ${GIT_REPO} (branch: ${GIT_BRANCH})"
rm -rf "${REPO_DIR}"
git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${REPO_DIR}"

echo "Building trend..."
cd "${REPO_DIR}"
mvn clean package -DskipTests -B -q

mkdir -p "${JAR_DIR}"
JAR_FILE=$(ls -t "${REPO_DIR}"/target/*.jar 2>/dev/null | grep -v original | head -1)

if [ -z "${JAR_FILE}" ]; then
    JAR_FILE=$(ls -t "${REPO_DIR}"/target/*.jar 2>/dev/null | head -1)
fi

if [ -z "${JAR_FILE}" ]; then
    echo "ERROR: No JAR found in target/"
    exit 1
fi

cp "${JAR_FILE}" "${JAR_DIR}/trend-job.jar"
echo "JAR saved: ${JAR_DIR}/trend-job.jar"

echo "Starting Flink JobManager..."
/opt/flink/bin/jobmanager.sh start-foreground &
JOBMANAGER_PID=$!

echo "Waiting for JobManager RPC..."
for i in $(seq 1 30); do
    if /opt/flink/bin/flink list -m localhost 2>/dev/null | grep -q "Running"; then
        break
    fi
    curl -sf http://localhost:8081/config > /dev/null 2>&1 && break
    sleep 2
done

submit_and_watch() {
    echo "Submitting trend Flink job..."
    /opt/flink/bin/flink run \
        -d \
        -c "${FLINK_MAIN_CLASS:-org.example.StreamingJob}" \
        "${JAR_DIR}/trend-job.jar" \
        2>&1 | tee /tmp/flink-submit.log

    JOB_ID=$(grep -oP 'JobID\s*=\s*\K[a-f0-9]+' /tmp/flink-submit.log | head -1)

    if [ -z "${JOB_ID}" ]; then
        echo "WARNING: Could not parse JobID, will retry submit in ${SUBMIT_INTERVAL}s"
        return 1
    fi

    echo "Job submitted: ${JOB_ID}"
    echo "Watching JobID: ${JOB_ID}"

    while true; do
        STATUS=$(curl -sf "http://localhost:8081/jobs/${JOB_ID}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "UNKNOWN")
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Job ${JOB_ID} state: ${STATUS}"

        case "${STATUS}" in
            RUNNING) sleep 30 ;;
            FINISHED)
                echo "Job completed successfully."
                return 0
                ;;
            FAILED|CANCELED)
                echo "Job ${STATUS}, will resubmit in ${SUBMIT_INTERVAL}s..."
                sleep "${SUBMIT_INTERVAL}"
                return 1
                ;;
            *) sleep 10 ;;
        esac
    done
}

while true; do
    if submit_and_watch; then
        echo "Job finished, exiting."
        break
    fi
    echo "Resubmitting..."
done &

wait "${JOBMANAGER_PID}"