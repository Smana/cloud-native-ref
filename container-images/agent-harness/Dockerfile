# syntax=docker/dockerfile:1
# The AgentRun harness (SP1 design §5, ADR-0041): OpenHands agent-server plus
# the driver, the git credential helper, gh, and the Agent-Run trailer hook.
# The AgentRun composition pins this image by digest; a claim never names one.
FROM ghcr.io/openhands/agent-server:1.49.5-python@sha256:1e7b08ffef732d6520e0b0048931b6ef425a7742c5fb80a82c9397a285c669eb AS harness

# `.github/workflows/build-container-images.yml` tags the image with this.
ARG AGENT_HARNESS_VERSION=v0.1.0
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.101.0
ARG GH_SHA256_AMD64=9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8
ARG GH_SHA256_ARM64=b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f
ARG TARGETARCH

USER root
# gh, checksum-pinned per architecture. The upstream image gives its user
# passwordless sudo; nothing here needs it and NoNewPrivileges is not reliable
# under gVisor (design §1), so sudo and every setuid bit go.
RUN set -eux; \
    case "${TARGETARCH}" in amd64) sum="${GH_SHA256_AMD64}" ;; arm64) sum="${GH_SHA256_ARM64}" ;; *) exit 1 ;; esac; \
    /usr/local/bin/python -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], '/tmp/gh.tgz')" \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    echo "${sum}  /tmp/gh.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/lib/gh-real; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"; \
    rm -f /etc/sudoers.d/*; \
    if [ -f /etc/sudoers ]; then sed -i '/NOPASSWD/d' /etc/sudoers; fi; \
    find / -xdev -perm -4000 -type f -exec chmod u-s {} +

# The SDK agent-run imports; see requirements.in for why it is not in the base image.
COPY requirements.txt /tmp/requirements.txt
RUN /usr/local/bin/python -m venv /agent-server/.venv \
 && /agent-server/.venv/bin/pip install --no-cache-dir --require-hashes -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

COPY --chmod=0755 agent_run.py git_credential_agent.py /opt/agent/
COPY --chmod=0755 gh /usr/local/bin/gh
COPY --chmod=0755 commit-msg /etc/agent/git-hooks/commit-msg
COPY gitconfig /etc/gitconfig
RUN ln -s /opt/agent/agent_run.py /usr/local/bin/agent-run \
 && ln -s /opt/agent/git_credential_agent.py /usr/local/bin/git-credential-agent

# agent-server otherwise starts openvscode-server on 0.0.0.0:8001, putting a
# terminal on the pod network that nothing in a headless run uses.
ENV OH_ENABLE_VSCODE=false
USER 10001
ENTRYPOINT ["tini", "--", "/usr/local/bin/agent-run"]

# `docker build --target test .` runs every suite against the SDK in the image.
FROM harness AS test
COPY --chown=10001:10001 tests /opt/agent/tests
RUN cd /opt/agent && /agent-server/.venv/bin/python -m unittest discover -s tests -v

# The default target, and what CI publishes.
FROM harness
