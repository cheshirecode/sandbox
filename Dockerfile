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
      git python3 python3-pip python3-yaml python3-venv python3-dev \
      build-essential bash less procps tini ffmpeg \
      libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
      libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
      libgbm1 libpango-1.0-0 libcairo2 libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# Astral uv — fast Python package and virtualenv manager for Hermes Agent & Python toolchains
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh \
    && uv --version

# gh apt source so the dotfiles installer can `apt install gh`.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends gh ripgrep jq direnv bubblewrap socat \
    && rm -rf /var/lib/apt/lists/*

# Node via NodeSource — evidence-based from n=3 dogfood: every
# repo (Next.js, Express, tape utility) needed Node + npm. Ubuntu apt
# ships Node 18 which can't run vitest 4 / vite 8 (`node:util.styleText`
# is Node 22+). Default Node 20 keeps the base image stable; set
# --build-arg NODE_MAJOR=22 or 24 when a repo pins a newer engine.
# ~80MB added to image; eliminates `sudo apt install nodejs npm` from every
# first-run.
ARG NODE_MAJOR=20
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# srt (Anthropic sandbox-runtime) — per-command filesystem + egress policy
# inside the sandbox. bubblewrap + socat come from the apt layer above.
# Containers lack privileged namespaces, so the default policy (see
# srt-settings.json) sets enableWeakerNestedSandbox — weaker than host srt,
# still a real deny-by-default egress allowlist for untrusted commands.
RUN npm install -g @anthropic-ai/sandbox-runtime \
    && srt --version

# Hermes Agent — pre-install via uv into /usr/local/lib/hermes-agent with global CLI wrapper
RUN uv venv /usr/local/lib/hermes-agent --python python3 \
    && /usr/local/lib/hermes-agent/bin/pip install --no-cache-dir hermes-agent \
    && ln -sf /usr/local/lib/hermes-agent/bin/hermes /usr/local/bin/hermes \
    || true

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
# IMPORTANT: pre-create the named-volume mount targets (.claude, .codex,
# .cache/toolchains, .config/gh) as dev-owned. On FIRST mount, docker copies
# the image's directory content into the empty named volume, preserving
# ownership. Without these dirs being dev-owned in the image, the volumes
# materialize root-owned and the dev-user entrypoint can't write credentials.
RUN mkdir -p \
      /workspace/oss \
      /workspace/home \
      /workspace/home/.claude \
      /workspace/home/.codex \
      /workspace/home/.hermes \
      /workspace/home/.cache/toolchains \
      /workspace/home/.config/gh \
      /workspace/inbox \
    && chown -R dev:dev /workspace

# --- Entrypoint + autosave scripts -----------------------------------------
COPY --chmod=0644 srt-settings.json /usr/local/share/sandbox/srt-settings.json
COPY --chmod=0755 entrypoint.sh /usr/local/bin/sandbox-entrypoint
COPY --chmod=0755 container-autosave.sh /usr/local/bin/container-autosave

# tini reaps zombies + forwards signals correctly (so STOPSIGNAL SIGTERM
# actually reaches the entrypoint shell, which is required for the EXIT
# trap to fire).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/sandbox-entrypoint"]
CMD ["bash", "-l"]
