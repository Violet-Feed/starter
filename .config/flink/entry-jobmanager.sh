#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="/opt/trend-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/trend.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"

JAR_DIR="/opt/flink/usrlib"
JOB_JAR="${JAR_DIR}/trend-job.jar"

SUBMIT_INTERVAL="${FLINK_SUBMIT_INTERVAL:-300}"
FLINK_MAIN="${FLINK_MAIN_CLASS:-violet.trending.flink.JobMain}"

BUILD_TREND_JOB="${BUILD_TREND_JOB:-true}"
REBUILD_TREND_JOB="${REBUILD_TREND_JOB:-false}"

APT_MIRROR="${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
APT_SECURITY_MIRROR="${APT_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"

MAVEN_MIRROR="${MAVEN_MIRROR:-https://maven.aliyun.com/repository/public}"
JDK_PACKAGE="${JDK_PACKAGE:-openjdk-17-jdk-headless}"
MAVEN_OPTS="${MAVEN_OPTS:--Xmx512m}"

JOBMANAGER_PID=""

cleanup() {
    echo "Received shutdown signal, stopping..."

    if [ -n "${JOBMANAGER_PID}" ] && kill -0 "${JOBMANAGER_PID}" 2>/dev/null; then
        kill "${JOBMANAGER_PID}" 2>/dev/null || true
        wait "${JOBMANAGER_PID}" 2>/dev/null || true
    fi
}

trap cleanup INT TERM

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

setup_maven_mirror() {
    echo "Configuring Maven mirror: ${MAVEN_MIRROR}"

    mkdir -p /root/.m2

    cat > /root/.m2/settings.xml <<EOF
<settings>
  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>*</mirrorOf>
      <name>Aliyun Maven</name>
      <url>${MAVEN_MIRROR}</url>
    </mirror>
  </mirrors>
</settings>
EOF
}

install_missing_deps() {
    local missing=()

    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v mvn >/dev/null 2>&1 || missing+=("maven")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

    if ! command -v javac >/dev/null 2>&1; then
        missing+=("${JDK_PACKAGE}")
    fi

    if [ "${#missing[@]}" -ne 0 ]; then
        setup_apt_mirror

        echo "Installing missing tools: ${missing[*]}"

        apt-get update -qq

        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            "${missing[@]}" \
            ca-certificates

        rm -rf /var/lib/apt/lists/*
    else
        echo "Required build tools already installed."
    fi

    setup_maven_mirror

    if command -v javac >/dev/null 2>&1; then
        JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
        export JAVA_HOME
        export PATH="${JAVA_HOME}/bin:${PATH}"

        echo "JAVA_HOME=${JAVA_HOME}"
        java -version || true
        javac -version || true
    else
        echo "WARNING: javac not found. Maven build may fail if project requires compilation."
    fi

    mvn -version || true
}

sync_repo() {
    echo "Syncing trend repo: ${GIT_REPO} branch ${GIT_BRANCH}"

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

build_trend_job() {
    mkdir -p "${JAR_DIR}"

    if [ "${BUILD_TREND_JOB}" != "true" ]; then
        echo "BUILD_TREND_JOB=${BUILD_TREND_JOB}, skip build."
        return 0
    fi

    if [ -s "${JOB_JAR}" ] && [ "${REBUILD_TREND_JOB}" != "true" ]; then
        echo "Existing job jar found: ${JOB_JAR}"
        echo "REBUILD_TREND_JOB=${REBUILD_TREND_JOB}, skip rebuild."
        return 0
    fi

    install_missing_deps
    sync_repo

    echo "Building trend..."
    cd "${REPO_DIR}"

    mvn -B -q \
        -s /root/.m2/settings.xml \
        -DskipTests \
        package

    local jar_file
    jar_file="$(
        find "${REPO_DIR}/target" -maxdepth 1 -type f -name "*.jar" ! -name "original-*.jar" \
        | sort \
        | tail -1
    )"

    if [ -z "${jar_file}" ]; then
        echo "ERROR: No runnable JAR found in ${REPO_DIR}/target"
        echo "Target directory:"
        ls -lah "${REPO_DIR}/target" || true
        exit 1
    fi

    cp "${jar_file}" "${JOB_JAR}"

    echo "JAR saved: ${JOB_JAR}"
}

start_jobmanager() {
    echo "Starting Flink JobManager..."

    /docker-entrypoint.sh jobmanager &

    JOBMANAGER_PID=$!
}

wait_for_jobmanager() {
    echo "Waiting for JobManager REST API..."

    for i in $(seq 1 90); do
        if curl -sf "http://localhost:8081/overview" >/dev/null 2>&1; then
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

    local submit_code="${PIPESTATUS[0]}"

    set -e

    if [ "${submit_code}" -ne 0 ]; then
        echo "WARNING: flink run failed with exit code ${submit_code}, will retry in ${SUBMIT_INTERVAL}s"
        sleep "${SUBMIT_INTERVAL}"
        return 1
    fi

    local job_id
    job_id="$(grep -Eo '[a-f0-9]{32}' /tmp/flink-submit.log | head -1 || true)"

    if [ -z "${job_id}" ]; then
        echo "WARNING: Could not parse JobID, will retry in ${SUBMIT_INTERVAL}s"
        cat /tmp/flink-submit.log || true
        sleep "${SUBMIT_INTERVAL}"
        return 1
    fi

    echo "Job submitted: ${job_id}"
    echo "Watching JobID: ${job_id}"

    while true; do
        if ! kill -0 "${JOBMANAGER_PID}" 2>/dev/null; then
            echo "ERROR: JobManager process exited."
            return 1
        fi

        local status
        status="$(
            curl -sf "http://localhost:8081/jobs/${job_id}" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('state', 'UNKNOWN'))" \
            2>/dev/null \
            || echo "UNKNOWN"
        )"

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Job ${job_id} state: ${status}"

        case "${status}" in
            RUNNING)
                sleep 30
                ;;
            FINISHED)
                echo "Job completed successfully."
                return 0
                ;;
            FAILED|CANCELED|FAILING|CANCELLING)
                echo "Job state is ${status}, will resubmit in ${SUBMIT_INTERVAL}s..."
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

build_trend_job

start_jobmanager
wait_for_jobmanager

while true; do
    if submit_and_watch; then
        echo "Job finished, exiting submit loop."
        break
    fi

    echo "Resubmitting..."
done &

wait "${JOBMANAGER_PID}"