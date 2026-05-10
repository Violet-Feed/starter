#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="/opt/swing-repo"
GIT_REPO="${GIT_REPO_URL:-https://github.com/Violet-Feed/swing.git}"
GIT_BRANCH="${GIT_REPO_BRANCH:-main}"

SPARK_APPS_DIR="/opt/spark-apps"
SPARK_EVENTS_DIR="/tmp/spark-events"

UBUNTU_APT_MIRROR="${UBUNTU_APT_MIRROR:-https://mirrors.aliyun.com/ubuntu}"
DEBIAN_APT_MIRROR="${DEBIAN_APT_MIRROR:-https://mirrors.aliyun.com/debian}"
DEBIAN_SECURITY_APT_MIRROR="${DEBIAN_SECURITY_APT_MIRROR:-https://mirrors.aliyun.com/debian-security}"

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
            ;;
    esac
}

install_missing_tools() {
    local missing=()

    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

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

install_python_deps() {
    echo "Installing Python dependencies for Spark ETL..."

    if ! command -v python3 >/dev/null 2>&1; then
        setup_apt_mirror
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3
        rm -rf /var/lib/apt/lists/*
    fi

    if ! python3 -m pip --version >/dev/null 2>&1; then
        setup_apt_mirror
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3-pip
        rm -rf /var/lib/apt/lists/*
    fi

    python3 -m pip install \
        -i https://pypi.tuna.tsinghua.edu.cn/simple \
        --no-cache-dir \
        pandas \
        pyarrow \
        redis \
        nebula3-python
}

prepare_spark_apps_dir() {
    if [ -e "${SPARK_APPS_DIR}" ] && [ ! -d "${SPARK_APPS_DIR}" ]; then
        echo "WARNING: ${SPARK_APPS_DIR} exists but is not a directory. Removing it..."
        rm -f "${SPARK_APPS_DIR}"
    fi

    mkdir -p "${SPARK_APPS_DIR}"

    if [ ! -d "${SPARK_APPS_DIR}" ]; then
        echo "ERROR: failed to create directory: ${SPARK_APPS_DIR}"
        ls -lah /opt || true
        exit 1
    fi
}

sync_repo() {
    echo "Syncing ETL scripts from ${GIT_REPO} (branch: ${GIT_BRANCH})..."

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

sync_etl_scripts() {
    prepare_spark_apps_dir

    if [ ! -d "${REPO_DIR}/etl" ]; then
        echo "ERROR: ETL directory not found: ${REPO_DIR}/etl"
        exit 1
    fi

    echo "Cleaning ${SPARK_APPS_DIR}..."
    rm -rf "${SPARK_APPS_DIR:?}"/* \
           "${SPARK_APPS_DIR:?}"/.[!.]* \
           "${SPARK_APPS_DIR:?}"/..?* 2>/dev/null || true

    echo "Copying ETL scripts to ${SPARK_APPS_DIR}..."
    cp -a "${REPO_DIR}/etl/." "${SPARK_APPS_DIR}/"

    echo "ETL scripts synced to ${SPARK_APPS_DIR}/"
    ls -lah "${SPARK_APPS_DIR}" || true
}

prepare_spark_runtime_dirs() {
    # Hadoop / JuiceFS 可能会查询 hdfs 用户所属用户组。
    # 如果容器里没有 hdfs 用户，会出现：
    # ShellBasedUnixGroupsMapping: unable to return groups for user hdfs
    if ! getent group hdfs >/dev/null 2>&1; then
        groupadd hdfs 2>/dev/null || true
    fi

    if ! id hdfs >/dev/null 2>&1; then
        useradd -m -g hdfs -s /bin/bash hdfs 2>/dev/null || true
    fi

    mkdir -p "${SPARK_EVENTS_DIR}"
    mkdir -p /home/spark
    mkdir -p /home/spark/.ivy2/cache
    mkdir -p /home/hdfs

    chown -R spark:spark /home/spark "${SPARK_EVENTS_DIR}" 2>/dev/null || true
    chown -R hdfs:hdfs /home/hdfs 2>/dev/null || true

    chmod -R 777 "${SPARK_EVENTS_DIR}" 2>/dev/null || true
}

download_spark_libs() {
    echo "Downloading Spark external libraries..."

    if [ ! -x /opt/spark/download-spark-libs.sh ]; then
        chmod +x /opt/spark/download-spark-libs.sh 2>/dev/null || true
    fi

    /opt/spark/download-spark-libs.sh /opt/spark/jars
}

start_spark_services() {
    echo "Starting Spark Master, Worker and HistoryServer..."

    /opt/spark/bin/spark-class org.apache.spark.deploy.master.Master &
    /opt/spark/bin/spark-class org.apache.spark.deploy.worker.Worker spark://spark:7077 &
    /opt/spark/bin/spark-class org.apache.spark.deploy.history.HistoryServer &

    wait
}

install_missing_tools
install_python_deps
sync_repo
sync_etl_scripts
download_spark_libs
prepare_spark_runtime_dirs
start_spark_services