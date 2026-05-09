#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="/opt/trend-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/trend.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"
JAR_DIR="/opt/flink/usrlib"
SUBMIT_INTERVAL="${FLINK_SUBMIT_INTERVAL:-300}"
FLINK_MAIN="${FLINK_MAIN_CLASS:-violet.trending.flink.JobMain}"
JOB_JAR="${JAR_DIR}/trend-job.jar"

JOBMANAGER_PID=""

cleanup() {
    echo "Received shutdown signal, stopping..."
    if [ -n "${JOBMANAGER_PID}" ] && kill -0 "${JOBMANAGER_PID}" 2>/dev/null; then
        kill "${JOBMANAGER_PID}" 2>/dev/null || true
        wait "${JOBMANAGER_PID}" 2>/dev/null || true
    fi
}

trap cleanup INT TERM

echo "Starting Flink JobManager..."
/docker-entrypoint.sh jobmanager &
JOBMANAGER_PID=$!

install_deps() {
    echo "Installing git, Maven, Python3, curl and full JDK..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git \
        maven \
        python3 \
        curl \
        ca-certificates \
        openjdk-21-jdk \

    rm -rf /var/lib/apt/lists/*

    if [ -d "/usr/lib/jvm/java-21-openjdk-amd64" ]; then
        export JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
    elif [ -d "/opt/java/openjdk" ]; then
        export JAVA_HOME="/opt/java/openjdk"
    else
        export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    fi

    export PATH="${JAVA_HOME}/bin:${PATH}"

    echo "JAVA_HOME=${JAVA_HOME}"
    java -version
    javac -version
    mvn -version
}

wait_for_jobmanager() {
    echo "Waiting for JobManager REST API..."

    for i in $(seq 1 90); do
        if curl -sf "http://localhost:8081/overview" > /dev/null 2>&1; then
            echo "JobManager REST API is ready."
            return 0
        fi

        if ! kill -0 "${JOBMANAGER_PID}" 2>/dev/null; then
            echo "ERROR: JobManager process exited before becoming ready."
            return 1
        fi

        sleep 2
    done

    echo "ERROR: JobManager REST API did not become ready in time."
    return 1
}

build_trend_job() {
    echo "Cloning trend: ${GIT_REPO} branch ${GIT_BRANCH}"

    rm -rf "${REPO_DIR}"
    git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${REPO_DIR}"

    echo "Building trend..."
    cd "${REPO_DIR}"

    if ! mvn clean package -DskipTests -B; then
        echo "ERROR: Maven build failed."
        echo "Check Java compiler and project compilation errors above."
        exit 1
    fi

    mkdir -p "${JAR_DIR}"

    JAR_FILE="$(
        find "${REPO_DIR}/target" -maxdepth 1 -type f -name "*.jar" ! -name "original-*.jar" \
        | sort \
        | tail -1
    )"

    if [ -z "${JAR_FILE}" ]; then
        echo "ERROR: No runnable JAR found in ${REPO_DIR}/target"
        echo "Target directory:"
        ls -lah "${REPO_DIR}/target" || true
        exit 1
    fi

    cp "${JAR_FILE}" "${JOB_JAR}"
    echo "JAR saved: ${JOB_JAR}"
}

submit_and_watch() {
    echo "Submitting trend Flink job..."
    echo "Main class: ${FLINK_MAIN}"
    echo "JAR: ${JOB_JAR}"

    if [ ! -s "${JOB_JAR}" ]; then
        echo "ERROR: Job JAR does not exist or is empty: ${JOB_JAR}"
        sleep "${SUBMIT_INTERVAL}"
        return 1
    fi

    set +e
    /opt/flink/bin/flink run \
        -m localhost:8081 \
        -d \
        -c "${FLINK_MAIN}" \
        "${JOB_JAR}" \
        2>&1 | tee /tmp/flink-submit.log
    SUBMIT_CODE="${PIPESTATUS[0]}"
    set -e

    if [ "${SUBMIT_CODE}" -ne 0 ]; then
        echo "WARNING: flink run failed with exit code ${SUBMIT_CODE}, will retry in ${SUBMIT_INTERVAL}s"
        sleep "${SUBMIT_INTERVAL}"
        return 1
    fi

    JOB_ID="$(
        grep -Eo '[a-f0-9]{32}' /tmp/flink-submit.log | head -1 || true
    )"

    if [ -z "${JOB_ID}" ]; then
        echo "WARNING: Could not parse JobID, will retry in ${SUBMIT_INTERVAL}s"
        cat /tmp/flink-submit.log || true
        sleep "${SUBMIT_INTERVAL}"
        return 1
    fi

    echo "Job submitted: ${JOB_ID}"
    echo "Watching JobID: ${JOB_ID}"

    while true; do
        if ! kill -0 "${JOBMANAGER_PID}" 2>/dev/null; then
            echo "ERROR: JobManager process exited."
            return 1
        fi

        STATUS="$(
            curl -sf "http://localhost:8081/jobs/${JOB_ID}" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('state', 'UNKNOWN'))" \
            2>/dev/null \
            || echo "UNKNOWN"
        )"

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Job ${JOB_ID} state: ${STATUS}"

        case "${STATUS}" in
            RUNNING)
                sleep 30
                ;;
            FINISHED)
                echo "Job completed successfully."
                return 0
                ;;
            FAILED|CANCELED|FAILING|CANCELLING)
                echo "Job state is ${STATUS}, will resubmit in ${SUBMIT_INTERVAL}s..."
                sleep "${SUBMIT_INTERVAL}"
                return 1
                ;;
            UNKNOWN)
                sleep 10
                ;;
            *)
                sleep 10
                ;;
        esac
    done
}

install_deps
wait_for_jobmanager
build_trend_job

while true; do
    if submit_and_watch; then
        echo "Job finished, exiting submit loop."
        break
    fi

    echo "Resubmitting..."
done &

wait "${JOBMANAGER_PID}"