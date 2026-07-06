# Dockerfile for Linux E2E Tests with systemd
# Provides Ubuntu environment with full systemd support for service testing

FROM ubuntu:22.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Install systemd and minimal packages.
# Note: Avoid pre-installing most OpenPath dependencies so the installer
# is exercised in E2E runs.
COPY linux/lib/apt.sh /tmp/openpath-apt.sh
RUN . /tmp/openpath-apt.sh \
    && apt_install_with_retry "systemd E2E base packages" apt-get install -y \
    systemd \
    systemd-sysv \
    iproute2 \
    procps \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Remove unnecessary systemd services that won't work in container
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
    /etc/systemd/system/*.wants/* \
    /lib/systemd/system/local-fs.target.wants/* \
    /lib/systemd/system/sockets.target.wants/*udev* \
    /lib/systemd/system/sockets.target.wants/*initctl* \
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
    /lib/systemd/system/systemd-update-utmp*

# Disable systemd-resolved so dnsmasq can use port 53
RUN systemctl mask systemd-resolved.service systemd-resolved.socket

# Create working directory
WORKDIR /openpath

# Copy only what the Linux E2E image needs
COPY VERSION ./VERSION
COPY linux/ ./linux/
COPY runtime/ ./runtime/
COPY windows/ ./windows/
COPY tests/e2e/ ./tests/e2e/
COPY tests/contracts/ ./tests/contracts/
COPY firefox-extension/manifest.json ./firefox-extension/manifest.json
COPY firefox-extension/_locales/ ./firefox-extension/_locales/
COPY firefox-extension/dist/ ./firefox-extension/dist/
COPY firefox-extension/popup/ ./firefox-extension/popup/
COPY firefox-extension/blocked/ ./firefox-extension/blocked/
COPY firefox-extension/native/ ./firefox-extension/native/
COPY firefox-extension/icons/ ./firefox-extension/icons/

# Make scripts executable (find is more reliable than globstar in /bin/sh)
RUN find linux tests/e2e -type f -name "*.sh" -exec chmod +x {} +

# Create the test runner service
RUN echo '[Unit]\n\
    Description=E2E Test Runner\n\
    After=multi-user.target\n\
    \n\
    [Service]\n\
    Type=oneshot\n\
    ExecStart=/openpath/tests/e2e/docker-e2e-runner.sh\n\
    StandardOutput=journal+console\n\
    StandardError=journal+console\n\
    RemainAfterExit=yes\n\
    \n\
    [Install]\n\
    WantedBy=multi-user.target' > /etc/systemd/system/e2e-tests.service

RUN systemctl enable e2e-tests.service

# Use systemd as entrypoint
STOPSIGNAL SIGRTMIN+3
VOLUME ["/sys/fs/cgroup"]
CMD ["/lib/systemd/systemd"]
