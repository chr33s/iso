# Guest image for tests/integration-apple-sandbox.sh.
# A persistent systemd machine userspace: sshd + Docker, no baked identity.
FROM --platform=linux/arm64 ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

ENV container=container \
    DEBIAN_FRONTEND=noninteractive

COPY machine-setup.sh /tmp/machine-setup.sh
COPY sshd.conf /etc/ssh/sshd_config.d/10-iso-test.conf
COPY verify.sh /usr/local/sbin/iso-test-verify
RUN bash /tmp/machine-setup.sh && rm -f /tmp/machine-setup.sh

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
