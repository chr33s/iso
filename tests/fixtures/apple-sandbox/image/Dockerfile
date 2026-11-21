# Guest image for tests/integration-apple-sandbox.sh.
# A persistent systemd machine userspace: sshd + Docker, no baked identity.
FROM --platform=linux/arm64 ubuntu:25.10@sha256:7cc5e35f6567ee8c66d2abb4aab0fd866669e6207c237c3a8f0947a5c7f17092

ENV container=container \
    DEBIAN_FRONTEND=noninteractive

COPY machine-setup.sh /tmp/machine-setup.sh
COPY sshd.conf /etc/ssh/sshd_config.d/10-iso-test.conf
COPY verify.sh /usr/local/sbin/iso-test-verify
RUN bash /tmp/machine-setup.sh && rm -f /tmp/machine-setup.sh

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
