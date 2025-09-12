#!/usr/bin/env bash
# superclaude-up.sh — Version-adaptive, idempotent SuperClaude bootstrap (macOS & Linux)
# Goals:
#   • Install LATEST SUPPORTED bits on current OS/CPU:
#       - Python user bin PATH sanity, pipx
#       - uv/uvx (for serena MCP)
#       - Node via nvm (prefer Node 22, fallback to Node 20 if 22 fails)
#       - Claude CLI (latest) via npm and shim to user bins
#       - SuperClaude (prefer latest git; fallback to PyPI)
#       - realpath (macOS coreutils) for serena wrapper
#   • Remove bad `alias claude=~/.claude/local/claude` and unify CLI resolution
#
# Env toggles:
#   SC_SOURCE=git|pypi       (default: git → “absolute latest”; use pypi for registry releases)
#   SC_YES=1                 (non-interactive `SuperClaude install --yes`)
#   SC_NO_APPLY=1            (skip running `SuperClaude install`)
#   SC_PERSIST_PATH=1        (append PATH/gnubin persistently to shell profile)
#   SC_SKIP_NODE=1           (skip Node/nvm management)
#   SC_CLAUDE_INSTALL=npm|skip  (default npm; set skip to avoid touching Claude CLI)
#   SC_INSTALL_NPM=1         (also install @bifrost_inc/superclaude wrapper – optional)
#   SC_SERENA=0              (skip serena prerequisites)
#
set -Eeuo pipefail

REPO_URL="https://github.com/SuperClaude-Org/SuperClaude_Framework.git"
PIP_PACKAGE="SuperClaude"
NPM_WRAPPER="@bifrost_inc/superclaude"

# ---------- UI ----------
say() { printf "\033[1;36m[info]\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m[  OK]\033[0m %s\n" "$*"; }
wrn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s 2>/dev/null || echo "?")"
PY="python3"; have python3 || { have python && PY="python"; }

ZSHRC="$HOME/.zshrc"; ZPROFILE="$HOME/.zprofile"
BASHRC="$HOME/.bashrc"; BASH_PROFILE="$HOME/.bash_profile"

# Version compare helpers
vernum(){ awk -F. '{printf("%03d%03d%03d\n",$1,$2,$3)}' <<<"${1:-0.0.0}"; }
ge_ver(){ [ "$(vernum "$1")" -ge "$(vernum "$2")" ]; }

# PATH helpers
ensure_path(){
  local seg="$1"
  case ":$PATH:" in *":$seg:"*) return 0;; esac
  export PATH="$seg:$PATH"
  wrn "Added $seg to PATH (session)"
}
persist_line(){
  local line="$1" file="$2"
  [ -f "$file" ] || return 0
  grep -qsF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}
persist_export(){
  [ "${SC_PERSIST_PATH:-0}" = "1" ] || return 0
  local text="$1" profile
  if [ -n "${ZSH_VERSION:-}" ] || [[ "${SHELL:-}" == *zsh* ]] || [ -f "$ZPROFILE" ]; then
    profile="$ZPROFILE"
  else
    profile="$BASH_PROFILE"
  fi
  touch "$profile"
  if ! grep -qsF "$text" "$profile"; then
    printf '%s\n' "$text" >> "$profile"
    ok "Persisted to $profile: $text"
  else
    ok "Already persisted in $profile"
  fi
}

# Kill rogue alias/function that masks the real Claude CLI
purge_bad_aliases(){
  (alias claude >/dev/null 2>&1) && unalias claude || true
  typeset -f claude >/dev/null 2>&1 && unset -f claude || true
  for f in "$ZSHRC" "$ZPROFILE" "$BASHRC" "$BASH_PROFILE" "$HOME/.zshenv" "$HOME/.profile"; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*alias[[:space:]]+claude=' "$f"; then
      sed -i.bak '/^[[:space:]]*alias[[:space:]]\+claude=/d' "$f"
      wrn "Removed alias 'claude=…' from $f (backup: $f.bak)"
    fi
  done
  for f in "$ZSHRC" "$ZPROFILE"; do
    [ -f "$f" ] || touch "$f"
    persist_line 'unalias claude 2>/dev/null || true' "$f"
  done
}

ensure_python(){
  if ! have "$PY"; then
    if [ "$OS" = "Darwin" ] && have brew; then
      wrn "Installing Python via Homebrew"
      brew install python || true
    fi
  fi
  have "$PY" || die "Python 3 not found. Install Python 3 and re-run."
  ok "Using $($PY -V 2>/dev/null)"
  local UB="$($PY -m site --user-base 2>/dev/null || echo "$HOME/.local")/bin"
  mkdir -p "$UB" "$HOME/.local/bin"
  ensure_path "$UB"
  ensure_path "$HOME/.local/bin"
  persist_export 'export PATH="$('"$PY"' -m site --user-base)/bin:$HOME/.local/bin:$PATH"'
}

ensure_pipx(){
  if ! have pipx; then
    wrn "Installing pipx"
    if [ "$OS" = "Darwin" ] && have brew; then brew install pipx || true; fi
    have pipx || $PY -m pip install --user -q pipx || die "pipx install failed"
  fi
  pipx ensurepath >/dev/null 2>&1 || true
  ok "pipx: $(command -v pipx)"
}

ensure_uv(){
  [ "${SC_SERENA:-1}" = "1" ] || return 0
  if have uvx || have uv; then ok "uv present"; return 0; fi
  wrn "Installing uv"
  if [ "$OS" = "Darwin" ] && have brew; then brew install uv || true; fi
  if ! have uvx && ! have uv; then
    have curl && curl -LsSf https://astral.sh/uv/install.sh | sh || wrn "uv install script failed"
    hash -r || true
  fi
  if have uvx || have uv; then ok "uv ready"; else wrn "uv still missing (serena may fail)"; fi
}

ensure_realpath(){
  [ "${SC_SERENA:-1}" = "1" ] || return 0
  if have realpath; then ok "realpath present"; return 0; fi
  if [ "$OS" = "Darwin" ]; then
    if have brew; then
      wrn "Installing coreutils for realpath"
      brew install coreutils || true
      local GNUBIN="/usr/local/opt/coreutils/libexec/gnubin"
      [ -d "$GNUBIN" ] && { ensure_path "$GNUBIN"; persist_export 'export PATH="/usr/local/opt/coreutils/libexec/gnubin:$PATH"'; }
      have realpath && ok "realpath available via coreutils" || wrn "realpath still missing"
    else
      wrn "Homebrew not found; cannot add realpath (serena may fail)"
    fi
  else
    wrn "On Linux, install coreutils via your package manager if realpath is missing"
  fi
}

ensure_nvm_loaded(){
  # shellcheck disable=SC1090
  [ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" && have nvm
}

install_nvm_if_missing(){
  ensure_nvm_loaded && return 0
  wrn "Installing nvm (user-space)"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  ensure_nvm_loaded || die "nvm not available after install"
}

ensure_node_latest_supported(){
  [ "${SC_SKIP_NODE:-0}" = "1" ] && { wrn "Skipping Node per SC_SKIP_NODE=1"; return 0; }
  install_nvm_if_missing
  # Try newest LTS (currently Node 22). If not supported/build fails → fallback to 20.
  say "Ensuring Node (prefer 22; fallback 20) via nvm"
  local installed=""
  if nvm install 22 >/dev/null 2>&1; then
    nvm use 22 >/dev/null 2>&1 || true
    installed="$(node -v 2>/dev/null || echo v0.0.0)"
    if [[ "$installed" == v22.* ]]; then
      nvm alias default 22 >/dev/null 2>&1 || true
      ok "Node $installed via nvm"
      return 0
    fi
  fi
  wrn "Node 22 not available; trying Node 20 LTS"
  nvm install 20 >/dev/null 2>&1 || die "Failed to install Node 20 with nvm"
  nvm use 20 >/dev/null 2>&1 || true
  installed="$(node -v 2>/dev/null || echo v0.0.0)"
  [[ "$installed" == v20.* ]] || wrn "Node version unexpected: $installed"
  nvm alias default 20 >/dev/null 2>&1 || true
  ok "Node $installed via nvm"
}

ensure_claude_cli(){
  purge_bad_aliases
  if [ "${SC_CLAUDE_INSTALL:-npm}" = "skip" ]; then
    wrn "Skipping Claude CLI install per SC_CLAUDE_INSTALL=skip"
  else
    have npm || die "npm not found; ensure Node installed"
    say "Installing/upgrading Claude CLI (@anthropic-ai/claude-code@latest)"
    npm -g install @anthropic-ai/claude-code@latest >/dev/null 2>&1 || npm -g install @anthropic-ai/claude-code@latest
  fi
  if have claude; then
    local CB; CB="$(command -v claude)"
    ok "Claude CLI: $(claude --version 2>/dev/null || echo '?') @ $CB"
    # Shim to user bins
    local UB="$($PY -m site --user-base)/bin"
    mkdir -p "$UB" "$HOME/.local/bin"
    ln -sf "$CB" "$UB/claude"
    ln -sf "$CB" "$HOME/.local/bin/claude"
    ok "Claude CLI shimmed to $UB and ~/.local/bin"
  else
    wrn "Claude CLI not on PATH after install (continuing)"
  fi
}

show_status(){
  for c in SuperClaude superclaude; do
    if have "$c"; then ok "$c: $($c --version 2>/dev/null || echo '?') @ $(command -v "$c")"; else wrn "$c not on PATH"; fi
  done
  if have claude; then ok "claude: $(claude --version 2>/dev/null || echo '?') @ $(command -v claude)"; else wrn "claude not on PATH"; fi
  have uvx && ok "uvx: $(command -v uvx)" || true
  have realpath && ok "realpath: $(command -v realpath)" || true
}

install_or_upgrade_superclaude(){
  local src="${SC_SOURCE:-git}"
  if [ "$src" = "git" ]; then
    say "Installing SuperClaude (latest) from git: $REPO_URL"
    # Force reinstall to ensure we’re on latest main
    pipx install --pip-args "--upgrade" --force "git+${REPO_URL}" || {
      wrn "git install failed; falling back to PyPI"
      pipx install --pip-args "--upgrade" --force "$PIP_PACKAGE"
    }
  else
    if pipx list 2>/dev/null | grep -qiE '^package (SuperClaude|superclaude) '; then
      say "Upgrading SuperClaude via pipx"
      pipx upgrade "$PIP_PACKAGE" || pipx reinstall "$PIP_PACKAGE" || pipx install --force "$PIP_PACKAGE"
    else
      say "Installing SuperClaude via pipx"
      pipx install "$PIP_PACKAGE"
    fi
  fi
}

apply_superclaude(){
  [ "${SC_NO_APPLY:-0}" = "1" ] && { wrn "Skipping SuperClaude install per SC_NO_APPLY=1"; return 0; }
  if have SuperClaude; then
    say "Running SuperClaude install (idempotent)"
    if [ "${SC_YES:-0}" = "1" ]; then SuperClaude install --yes || wrn "'SuperClaude install' returned non-zero"
    else SuperClaude install || wrn "'SuperClaude install' returned non-zero"
    fi
  elif have superclaude; then
    say "Running superclaude install (npm wrapper)"
    superclaude install || wrn "'superclaude install' returned non-zero"
  else
    wrn "SuperClaude CLI not found after install"
  fi
}

maybe_install_npm_wrapper(){
  [ "${SC_INSTALL_NPM:-0}" = "1" ] || return 0
  have npm || { wrn "npm not found; skipping npm wrapper"; return 0; }
  say "Installing/upgrading npm wrapper: $NPM_WRAPPER"
  if npm -g ls "$NPM_WRAPPER" --depth=0 >/dev/null 2>&1; then npm -g update "$NPM_WRAPPER" || wrn "npm update failed"
  else npm -g install "$NPM_WRAPPER" || wrn "npm install failed"; fi
  have superclaude && ok "npm wrapper: $(superclaude --version 2>/dev/null || echo '?')" || wrn "npm wrapper not on PATH"
}

main(){
  say "=== SuperClaude updater (version-adaptive, idempotent) ==="
  ensure_python
  ensure_pipx
  ensure_uv
  ensure_realpath
  ensure_node_latest_supported
  ensure_claude_cli
  show_status
  install_or_upgrade_superclaude
  show_status
  apply_superclaude
  maybe_install_npm_wrapper
  ok "Done. Re-run this script any time to stay up-to-date."
}
main "$@"
