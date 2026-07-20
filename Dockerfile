# Base developer image: tmux + neovim (kickstart.nvim-derived config) + Claude Code.
# Derive language-specific images (python, rust, ...) from this one.

FROM debian:trixie-slim

ARG NVIM_VERSION=v0.12.4
ARG NODE_MAJOR=22
ARG TARGETARCH
ARG KICKSTART_REPO=https://github.com/Foo42/kickstart.nvim.git
ARG KICKSTART_REF=be250b784091bcc0df85aff74ed3e210e903ecc4
ARG DOTFILES_REPO=https://github.com/Foo42/dot-conf-files.git
ARG DOTFILES_REF=92103f88e6d69408c0159273635b430b74575fa9

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
# tree-sitter-cli is also installed here (via npm, since Node is already
# present): nvim-treesitter's rewritten build system shells out to the
# `tree-sitter` binary (`tree-sitter build`) to compile parsers, rather than
# invoking a C compiler directly like the old build system did.
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code tree-sitter-cli

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

# Neovim config: cloned directly from GitHub and pinned to a known-good
# commit, rather than copied from a local checkout, so the image is
# self-contained and reproducible on any machine.
RUN git clone "${KICKSTART_REPO}" /home/dev/.config/kickstart \
    && git -C /home/dev/.config/kickstart checkout "${KICKSTART_REF}"

# tmux config: cloned from GitHub (same repo/commit-pinning approach as the
# nvim config above) and pinned to a known-good commit.
RUN git clone "${DOTFILES_REPO}" /tmp/dot-conf-files \
    && git -C /tmp/dot-conf-files checkout "${DOTFILES_REF}" \
    && cp /tmp/dot-conf-files/tmux/.tmux.conf /home/dev/.tmux.conf \
    && rm -rf /tmp/dot-conf-files

# TPM (Tmux Plugin Manager) and its plugins.
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
