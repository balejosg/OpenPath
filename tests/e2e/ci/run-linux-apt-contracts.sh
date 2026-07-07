#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

IMAGE_TAG="${OPENPATH_APT_CONTRACT_IMAGE_TAG:-openpath-apt-contracts:latest}"
CONTAINER_NAME="${OPENPATH_APT_CONTRACT_CONTAINER_NAME:-openpath-apt-contracts-$$}"
SERVER_PORT="${OPENPATH_APT_CONTRACT_PORT:-18082}"

_context_dir=""
_repo_dir=""
_gnupg_home=""

cleanup() {
    if [ -n "${CONTAINER_NAME:-}" ]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if [ -n "${_context_dir:-}" ] && [ -d "$_context_dir" ]; then
        rm -rf "$_context_dir" || true
    fi

    if [ -n "${_repo_dir:-}" ] && [ -d "$_repo_dir" ]; then
        rm -rf "$_repo_dir" || true
    fi

    if [ -n "${_gnupg_home:-}" ] && [ -d "$_gnupg_home" ]; then
        rm -rf "$_gnupg_home" || true
    fi

    return 0
}

debug_container() {
    echo ""
    echo "APT contract container diagnostics..."
    docker ps -a || true
    echo ""
    docker exec "$CONTAINER_NAME" systemctl --no-pager --failed 2>/dev/null || true
    echo ""
    docker exec "$CONTAINER_NAME" journalctl --no-pager -n 200 2>/dev/null || true
}

on_error() {
    local rc=$?
    echo ""
    echo "Linux APT contracts failed (exit code: $rc)"
    debug_container
    exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
}

require_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "Missing required file: $path" >&2
        exit 1
    fi
}

require_dir() {
    local path="$1"
    if [ ! -d "$path" ]; then
        echo "Missing required directory: $path" >&2
        exit 1
    fi
}

wait_for_systemd() {
    local max_iters=24
    local sleep_sec=2

    for _ in $(seq 1 "$max_iters"); do
        state="$(docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null || true)"
        case "$state" in
            running|degraded)
                return 0
                ;;
        esac
        sleep "$sleep_sec"
    done

    echo "Timed out waiting for systemd to boot" >&2
    return 1
}

create_context() {
    local tmp
    tmp="$(mktemp -d -t openpath-apt-contracts.XXXXXXXX)"

    mkdir -p "$tmp/linux" "$tmp/runtime"
    cp -a "$PROJECT_ROOT/linux/." "$tmp/linux/"
    cp -a "$PROJECT_ROOT/runtime/." "$tmp/runtime/"
    cp -a "$PROJECT_ROOT/VERSION" "$tmp/"
    require_file "$PROJECT_ROOT/runtime/browser-policy-spec.json"

    cat > "$tmp/Dockerfile" <<'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

COPY linux/lib/apt.sh /tmp/openpath-apt.sh
RUN . /tmp/openpath-apt.sh \
    && apt_install_with_retry "APT contract base packages" apt-get install -y \
    systemd \
    systemd-sysv \
    iproute2 \
    procps \
    curl \
    gnupg \
    ca-certificates \
    python3 \
    && rm -rf /var/lib/apt/lists/*

RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
    /etc/systemd/system/*.wants/* \
    /lib/systemd/system/local-fs.target.wants/* \
    /lib/systemd/system/sockets.target.wants/*udev* \
    /lib/systemd/system/sockets.target.wants/*initctl* \
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
    /lib/systemd/system/systemd-update-utmp*

WORKDIR /openpath
COPY VERSION ./VERSION
COPY linux/ ./linux/
COPY runtime/ ./runtime/

STOPSIGNAL SIGRTMIN+3
VOLUME ["/sys/fs/cgroup"]
CMD ["/lib/systemd/systemd"]
EOF

    echo "$tmp"
}

build_package() {
    local version="$1"

    require_file "$PROJECT_ROOT/firefox-extension/manifest.json"
    require_dir "$PROJECT_ROOT/firefox-extension/dist"
    require_dir "$PROJECT_ROOT/firefox-extension/popup"
    require_dir "$PROJECT_ROOT/firefox-extension/blocked"
    require_dir "$PROJECT_ROOT/firefox-extension/native"
    require_dir "$PROJECT_ROOT/firefox-extension/icons"

    (
        cd "$PROJECT_ROOT"
        ./linux/scripts/build/build-deb.sh "$version" 1
    )
}

create_local_apt_repo() {
    local version="$1"
    local package_path="$PROJECT_ROOT/build/openpath-dnsmasq_${version}-1_amd64.deb"
    local key_id=""
    local release_dir=""
    local pool_dir=""

    require_file "$package_path"

    _repo_dir="$(mktemp -d -t openpath-apt-repo.XXXXXXXX)"
    _gnupg_home="$(mktemp -d -t openpath-apt-gpg.XXXXXXXX)"
    chmod 700 "$_gnupg_home"
    release_dir="$_repo_dir/dists/stable"
    pool_dir="$_repo_dir/pool/main"

    GNUPGHOME="$_gnupg_home" gpg --batch --pinentry-mode loopback --passphrase '' \
        --quick-gen-key "OpenPath Test APT <apt-test@openpath.local>" rsa3072 sign 0

    key_id="$(
        GNUPGHOME="$_gnupg_home" gpg --batch --with-colons --list-secret-keys \
            | awk -F: '/^fpr:/ { print $10; exit }'
    )"

    if [ -z "$key_id" ]; then
        echo "Failed to generate a temporary GPG key for APT contracts" >&2
        exit 1
    fi

    mkdir -p "$release_dir/main/binary-amd64" "$pool_dir"
    cp "$package_path" "$pool_dir/"
    cp "$PROJECT_ROOT/linux/scripts/build/apt-setup.sh" "$_repo_dir/apt-setup.sh"

    (
        cd "$_repo_dir"
        dpkg-scanpackages --arch amd64 pool > "dists/stable/main/binary-amd64/Packages"
    )
    gzip -kf "$release_dir/main/binary-amd64/Packages"

    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="OpenPath Test APT" \
        -o APT::FTPArchive::Release::Label="OpenPath Test APT" \
        -o APT::FTPArchive::Release::Suite="stable" \
        -o APT::FTPArchive::Release::Codename="stable" \
        -o APT::FTPArchive::Release::Architectures="amd64" \
        -o APT::FTPArchive::Release::Components="main" \
        release "$release_dir" > "$release_dir/Release"

    GNUPGHOME="$_gnupg_home" gpg --batch --yes --pinentry-mode loopback --default-key "$key_id" \
        --armor --detach-sign -o "$release_dir/Release.gpg" "$release_dir/Release"
    GNUPGHOME="$_gnupg_home" gpg --batch --yes --pinentry-mode loopback --default-key "$key_id" \
        --clearsign -o "$release_dir/InRelease" "$release_dir/Release"
    GNUPGHOME="$_gnupg_home" gpg --armor --export "$key_id" > "$_repo_dir/pubkey.gpg"
}

start_container() {
    _context_dir="$(create_context)"
    docker build -t "$IMAGE_TAG" -f "$_context_dir/Dockerfile" "$_context_dir"

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER_NAME" \
        --privileged \
        --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "$IMAGE_TAG" >/dev/null

    wait_for_systemd
    docker exec "$CONTAINER_NAME" mkdir -p /tmp/openpath-apt-repo
    docker cp "$_repo_dir/." "$CONTAINER_NAME:/tmp/openpath-apt-repo/"
    docker exec "$CONTAINER_NAME" bash -lc "
        set -euo pipefail
        nohup python3 -m http.server '$SERVER_PORT' --bind 127.0.0.1 --directory /tmp/openpath-apt-repo \
            >/tmp/openpath-apt-http.log 2>&1 &
    "

    docker exec "$CONTAINER_NAME" bash -lc "
        set -euo pipefail
        for _ in \$(seq 1 20); do
            if curl -fsS 'http://127.0.0.1:${SERVER_PORT}/pubkey.gpg' >/dev/null 2>&1; then
                exit 0
            fi
            sleep 0.5
        done
        echo 'Timed out waiting for local in-container APT repository server' >&2
        exit 1
    "
}

run_contracts() {
    local version="$1"
    local repo_url="http://127.0.0.1:${SERVER_PORT}"

    docker exec "$CONTAINER_NAME" bash -lc "
        set -euo pipefail
        export OPENPATH_APT_REPO_URL='$repo_url'
        /openpath/linux/scripts/build/apt-setup.sh --stable
        grep -q \"$repo_url stable main\" /etc/apt/sources.list.d/openpath.list
        test -f /usr/share/keyrings/openpath.gpg
    "

    docker exec "$CONTAINER_NAME" bash -lc "
        set -euo pipefail
        export OPENPATH_APT_REPO_URL='$repo_url'
        /openpath/linux/scripts/build/apt-setup.sh --stable
    "

    docker exec "$CONTAINER_NAME" bash -lc "
        set -euo pipefail
        export OPENPATH_APT_REPO_URL='$repo_url'
        /openpath/linux/scripts/build/apt-bootstrap.sh --skip-setup --package-version '$version'
        dpkg -s openpath-dnsmasq | grep -q 'Version: ${version}-1'
        test -f /etc/dnsmasq.d/openpath.conf
        grep -q 'OPENPATH_DNS_SINKHOLE_IPV4:-192.0.2.1' /usr/local/lib/openpath/lib/defaults.conf
        grep -q 'OPENPATH_DNS_SINKHOLE_IPV6:-100::' /usr/local/lib/openpath/lib/defaults.conf
        test -f /usr/local/lib/openpath/lib/dns-firewall-contract.sh
        ! grep -RsnE '^address=/#/$|blocked-test\.invalid' \
            /etc/dnsmasq.d/openpath.conf \
            /usr/local/lib/openpath \
            /usr/local/bin/openpath \
            /usr/local/bin/openpath-update.sh
        command -v openpath >/dev/null
        test ! -f /usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json
        systemctl is-enabled openpath-dnsmasq.timer >/dev/null
    "

    docker exec "$CONTAINER_NAME" bash -lc '
        set -euo pipefail
        /openpath/linux/uninstall.sh --auto-yes
        test ! -e /etc/dnsmasq.d/openpath.conf
        test ! -e /usr/local/bin/openpath-update.sh
        test ! -d /usr/local/lib/openpath
    '
}

main() {
    local version

    require_cmd docker
    require_cmd gpg
    require_cmd dpkg-scanpackages
    require_cmd apt-ftparchive

    version="$(cat "$PROJECT_ROOT/VERSION")"

    build_package "$version"
    create_local_apt_repo "$version"
    start_container
    run_contracts "$version"

    echo ""
    echo "Linux APT bootstrap contracts passed"
}

main "$@"
