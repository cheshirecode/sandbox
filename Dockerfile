# sandbox — ephemeral dev sandbox for cheshirecode/* repos.
#
# Layered for cache: system deps (slow, changes rarely) → runtime deps from
# the dotfiles installer (changes occasionally) → entrypoint copy (changes
# often). Build with --build-arg HOST_UID=$(id -u) on Linux/WSL2; macOS Docker
# Desktop and OrbStack fake ownership across bind mounts so the arg is dead
# weight there but harmless.
#
# NOTE on duplication with the paired dotfiles repo's Dockerfile.test-matrix:
# ~5 lines overlap (apt base + gh keyring). Council item #9 considered
# sharing; deferred because cross-repo cost (registry image or submodule)
# outweighs the savings. If a third image joins, publish to ghcr.io.
# Divergence: this file is a dev container (tini + entrypoint + STOPSIGNAL).
# The dotfiles test-matrix is a CI-only static-lint + install + doctor image.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/workspace/home \
    SHELL=/bin/bash

# Allow STOPSIGNAL TERM autosave trap to fire before docker stop SIGKILLs.
STOPSIGNAL SIGTERM

# --- System layer -----------------------------------------------------------
# Minimal set that bin/install-runtime-deps.sh assumes already present (sudo,
# curl, apt sources). Heavy deps are delegated to that script in the next
# layer so the install pathway matches a fresh machine bootstrap.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg sudo \
      git python3 python3-pip python3-yaml \
      bash less procps tini \
    && rm -rf /var/lib/apt/lists/*

# gh apt source so the dotfiles installer can `apt install gh`.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends gh ripgrep jq direnv \
    && rm -rf /var/lib/apt/lists/*

# --- User layer -------------------------------------------------------------
# UID arg matters on Linux (real ownership on bind mounts); on macOS/OrbStack
# VirtioFS fakes ownership so it's cosmetic. Default 1000 is the Ubuntu norm.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupadd -g "$HOST_GID" dev 2>/dev/null || groupmod -n dev "$(getent group $HOST_GID | cut -d: -f1)" \
    && useradd -m -u "$HOST_UID" -g dev -s /bin/bash -d /home/dev dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# /workspace skeleton — actual content is bind-mounted at runtime.
RUN mkdir -p /workspace/oss /workspace/home /workspace/inbox \
    && chown -R dev:dev /workspace

# --- Entrypoint + autosave scripts -----------------------------------------
COPY --chmod=0755 entrypoint.sh /usr/local/bin/sandbox-entrypoint
COPY --chmod=0755 container-autosave.sh /usr/local/bin/container-autosave

# tini reaps zombies + forwards signals correctly (so STOPSIGNAL SIGTERM
# actually reaches the entrypoint shell, which is required for the EXIT
# trap to fire).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/sandbox-entrypoint"]
CMD ["bash", "-l"]
