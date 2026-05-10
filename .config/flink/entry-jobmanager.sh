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

UBUNTU_APT_MIRROR="${UBUNTU_APT_MIRROR:-https://mirrors.aliyun.com/ubuntu}"
DEBIAN_APT_MIRROR="${DEBIAN_APT_MIRROR:-https://mirrors.aliyun.com/debian}"
DEBIAN_SECURITY_APT_MIRROR="${DEBIAN_SECURITY_APT_MIRROR:-https://mirrors.aliyun.com/debian-security}"

MAVEN_MIRROR="${MAVEN_MIRROR:-https://maven.aliyun.com/repository/public}"

REQUIRED_JAVA_MAJOR="${REQUIRED_JAVA_MAJOR:-21}"
JDK_PACKAGE="${JDK_PACKAGE:-openjdk-21-jdk-headless}"

MAVEN_OPTS="${MAVEN_OPTS:--Xmx512m}"
export MAVEN_OPTS

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

    local distro_id="${ID:-}"
    local codename="${VERSION_CODENAME:-}"

    if [ -z "${distro_id}" ] || [ -z "${codename}" ]; then
        echo "WARNING: cannot detect distro or codename, skip apt mirror setup."
        return 0
    fi

    echo "Detected distro: ${distro_id}"
    echo "Detected codename: ${codename}"

    rm -f /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true

    case "${distro_id}" in
        ubuntu)
            echo "Using Ubuntu APT mirror: ${UBUNTU_APT_MIRROR}"

            cat > /etc/apt/sources.list <<EOF
deb ${UBUNTU_APT_MIRROR} ${codename} main restricted universe multiverse
deb ${UBUNTU_APT_MIRROR} ${codename}-updates main restricted universe multiverse
deb ${UBUNTU_APT_MIRROR} ${codename}-backports main restricted universe multiverse
deb ${UBUNTU_APT_MIRROR} ${codename}-security main restricted universe multiverse
EOF
            ;;

        debian)
            echo "Using Debian APT mirror: ${DEBIAN_APT_MIRROR}"
            echo "Using Debian security mirror: ${DEBIAN_SECURITY_APT_MIRROR}"

            cat > /etc/apt/sources.list <<EOF
deb ${DEBIAN_APT_MIRROR} ${codename} main contrib non-free non-free-firmware
deb ${DEBIAN_APT_MIRROR} ${codename}-updates main contrib non-free non-free-firmware
deb ${DEBIAN_SECURITY_APT_MIRROR} ${codename}-security main contrib non-free non-free-firmware
EOF
            ;;

        *)
            echo "WARNING: unsupported distro ID=${distro_id}, skip apt mirror setup."
            return 0
            ;;
    esac
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

javac_major_from_bin() {
    local javac_bin="$1"

    if [ ! -x "${javac_bin}" ]; then
        echo "0"
        return 0
    fi

    local version
    version="$("${javac_bin}" -version 2>&1 | awk '{print $2}')"

    case "${version}" in
        1.*)
            echo "${version}" | cut -d. -f2
            ;;
        *)
            echo "${version}" | cut -d. -f1
            ;;
    esac
}

find_java_home_for_major() {
    local required="$1"
    local candidates=()

    candidates+=("/opt/java/openjdk")
    candidates+=("/usr/lib/jvm/java-${required}-openjdk-amd64")
    candidates+=("/usr/lib/jvm/java-${required}-openjdk")
    candidates+=("/usr/lib/jvm/temurin-${required}-jdk-amd64")
    candidates+=("/usr/lib/jvm/default-java")

    if [ -d /usr/lib/jvm ]; then
        while IFS= read -r dir; do
            candidates+=("${dir}")
        done < <(find /usr/lib/jvm -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r)
    fi

    for dir in "${candidates[@]}"; do
        if [ -x "${dir}/bin/javac" ]; then
            local major
            major="$(javac_major_from_bin "${dir}/bin/javac")"

            if [ "${major}" -ge "${required}" ]; then
                echo "${dir}"
                return 0
            fi
        fi
    done

    return 1
}

select_required_java_home() {
    local java_home

    if java_home="$(find_java_home_for_major "${REQUIRED_JAVA_MAJOR}")"; then
        export JAVA_HOME="${java_home}"
        export PATH="${JAVA_HOME}/bin:${PATH}"

        echo "Selected JAVA_HOME=${JAVA_HOME}"
        java -version || true
        javac -version || true
        return 0
    fi

    return 1
}

install_missing_deps() {
    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [ "${BUILD_TREND_JOB}" = "true" ]; then
        command -v git >/dev/null 2>&1 || missing+=("git")
        command -v mvn >/dev/null 2>&1 || missing+=("maven")

        if ! select_required_java_home >/dev/null 2>&1; then
            echo "Required JDK ${REQUIRED_JAVA_MAJOR} not found. Will try to install ${JDK_PACKAGE}."
            missing+=("${JDK_PACKAGE}")
        fi
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
        echo "Required tools already installed."
    fi

    setup_maven_mirror

    if [ "${BUILD_TREND_JOB}" = "true" ]; then
        if ! select_required_java_home; then
            echo "ERROR: javac for Java ${REQUIRED_JAVA_MAJOR}+ not found."
            echo "Current javac:"
            command -v javac || true
            javac -version || true
            echo ""
            echo "The project requires target release ${REQUIRED_JAVA_MAJOR}."
            echo "Please use a Flink image that contains JDK ${REQUIRED_JAVA_MAJOR}, or install ${JDK_PACKAGE} successfully."
            exit 1
        fi
    fi

    if command -v mvn >/dev/null 2>&1; then
        mvn -version || true
    fi
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

    sync_repo

    echo "Building trend..."
    cd "${REPO_DIR}"

    echo "Build Java version:"
    java -version || true
    javac -version || true

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

install_missing_deps
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