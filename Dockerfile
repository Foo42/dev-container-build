# Base developer image: tmux + neovim (kickstart.nvim-derived config) + Claude Code.
# Derive language-specific images (python, rust, ...) from this one.

FROM debian:bookworm-slim

ARG NVIM_VERSION=v0.11.4
ARG NODE_MAJOR=22
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      unzip \
      ca-certificates \
      build-essential \
      ripgrep \
      fd-find \
      xclip \
      tmux \
      python3 \
      python3-pip \
      python3-venv \
      locales \
      sudo \
    && rm -rf /var/lib/apt/lists/*

# fd-find installs as `fdfind` on Debian; kickstart/telescope expect `fd`.
RUN ln -s /usr/bin/fdfind /usr/local/bin/fd
# dap-python falls back to plain `python` on PATH when Mason's debugpy isn't installed.
RUN ln -s /usr/bin/python3 /usr/local/bin/python

# Node.js (LTS) + Claude Code CLI.
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# Neovim: install latest stable release binary rather than the (older) apt package.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) NVIM_ARCH=x86_64 ;; \
      arm64) NVIM_ARCH=arm64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/nvim-linux.tar.gz \
      "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${NVIM_ARCH}.tar.gz" \
    && tar -C /usr/local --strip-components=1 -xzf /tmp/nvim-linux.tar.gz \
    && rm /tmp/nvim-linux.tar.gz

# Non-root user with passwordless sudo.
RUN useradd --create-home --shell /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

USER dev
WORKDIR /home/dev
ENV HOME=/home/dev
ENV PATH="/home/dev/.local/bin:${PATH}"
# Selects ~/.config/kickstart instead of the default ~/.config/nvim, matching
# how this config is actually used locally.
ENV NVIM_APPNAME=kickstart

# Neovim config.
COPY --chown=dev:dev config/kickstart /home/dev/.config/kickstart

# tmux config + TPM (Tmux Plugin Manager) and its plugins.
COPY --chown=dev:dev tmux.conf /home/dev/.tmux.conf
RUN git clone --depth 1 https://github.com/tmux-plugins/tpm /home/dev/.tmux/plugins/tpm \
    && /home/dev/.tmux/plugins/tpm/bin/install_plugins

# Pre-install all LazyVim/kickstart plugins so the image starts ready to use.
# Use `install`, not `sync`: sync also updates every plugin to latest
# upstream and overwrites lazy-lock.json with those new commits, which can
# drift from (and break relative to) the exact versions your local nvim
# actually runs. `install` only clones what's missing and honors the
# existing lockfile pins as-is.
# (Language servers via Mason are intentionally left to derived images.)
# A second launch is required: newly-cloned plugins aren't fully registered
# on the runtimepath until the nvim process that installed them exits, so
# the very first launch after a fresh install spuriously errors on requires.
RUN nvim --headless "+Lazy! install" +qa \
    && nvim --headless -c "qa" || true

CMD ["/bin/bash"]
