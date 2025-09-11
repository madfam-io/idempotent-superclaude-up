#!/usr/bin/env bash
# Idempotent SuperClaude bootstrap/upgrade script (macOS/Linux)
# - Ensures Python 3, pipx, uv/uvx (serena MCP), Node/npm (if needed), and Claude CLI
# - Installs/updates SuperClaude via pipx (PyPI by default, GitHub optional)
# - Applies the command set via `SuperClaude install` (idempotent)
#
# ENV options when running:
#   SC_SOURCE=pypi|git         # default: pypi; 'git' uses upstream repo
#   SC_INSTALL_NPM=1           # also install/update the npm wrapper
#   SC_PERSIST_PATH=1          # append PATH fixes to your shell profile
#   SC_NO_APPLY=1              # skip running "SuperClaude install"
#   SC_CLAUDE_INSTALL=npm|brew # force method for Claude CLI
set -euo pipefail

REPO_URL="https://github.com/SuperClaude-Org/SuperClaude_Framework.git"
PIP_PACKAGE="SuperClaude"
NPM_PACKAGE="@bifrost_inc/superclaude"

log()  { printf "\033[1;34m[info]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[ ok ]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[err ]\033[0m %s\n" "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_python() {
  if need_cmd python3; then PY=python3
  elif need_cmd python; then PY=python
  elif need_cmd brew; then
    warn "Python not found; installing via Homebrew"
    brew install python || err "Failed to install python"
    PY=python3
  else
    err "Python not found and Homebrew unavailable. Install Python 3 and re-run."; exit 1
  fi
  ok "Using Python: $($PY -V 2>/dev/null)"
}

export_user_bin() {
  local USER_BASE USER_BIN
  USER_BASE="$($PY -m site --user-base 2>/dev/null || echo "$HOME/Library/Python/3.11")"
  USER_BIN="$USER_BASE/bin"
  case ":$PATH:" in
    *":$USER_BIN:"*) ;;
    *) export PATH="$USER_BIN:$HOME/.local/bin:$PATH"
       warn "Added $USER_BIN to PATH for this session"
       ;;
  esac
  USER_BIN_PATH="$USER_BIN"  # for persistence
}

persist_path_if_requested() {
  [[ "${SC_PERSIST_PATH:-0}" != "1" ]] && return 0
  local profile
  if [[ -n "${ZSH_VERSION:-}" || "${SHELL:-}" == *"zsh"* ]]; then profile="$HOME/.zprofile"; else profile="$HOME/.bash_profile"; fi
  [[ -f "$profile" ]] || touch "$profile"
  if ! grep -qs "$USER_BIN_PATH" "$profile"; then
    printf 'export PATH="%s:$HOME/.local/bin:$PATH"\n' "$USER_BIN_PATH" >> "$profile"
    ok "Persisted PATH to $profile"
  else
    ok "PATH already persisted in $profile"
  fi
}

ensure_pipx() {
  if need_cmd pipx; then
    ok "pipx found: $(command -v pipx)"
    pipx ensurepath >/dev/null 2>&1 || true
    return 0
  fi
  warn "pipx not found; attempting install"
  if need_cmd brew; then brew install pipx || true; fi
  if ! need_cmd pipx; then
    $PY -m pip install --user -q pipx || { err "Failed to install pipx"; exit 1; }
  fi
  need_cmd pipx || { err "pipx still not on PATH"; exit 1; }
  pipx ensurepath >/dev/null 2>&1 || true
  ok "pipx ready"
}

ensure_node() {
  # Only needed if we install Claude CLI via npm or for Playwright
  if need_cmd node && need_cmd npm; then return 0; fi
  if [[ "${SC_CLAUDE_INSTALL:-}" == "npm" ]] || ! need_cmd brew; then
    warn "Node/npm missing; Claude CLI via npm may fail without them."
    return 0
  fi
  warn "Installing Node via Homebrew"
  brew install node || warn "Homebrew Node install failed"
}

ensure_claude_cli() {
  # Ensure Anthropic Claude Code CLI is available for MCP server management
  if need_cmd claude; then ok "Claude CLI found: $(command -v claude)"; return 0; fi
  local method="${SC_CLAUDE_INSTALL:-}"
  if [[ "$method" == "brew" ]]; then
    if need_cmd brew; then
      warn "Installing Claude CLI via Homebrew cask"
      brew install --cask claude-code || warn "brew cask install failed"
    else
      warn "Homebrew not available; cannot use brew method"
    fi
  else
    # Default: npm first if available
    if need_cmd npm; then
      warn "Installing Claude CLI via npm"
      npm install -g @anthropic-ai/claude-code || warn "npm install of claude-code failed"
      if need_cmd npm; then
        local NPM_BIN
        NPM_BIN="$(npm bin -g 2>/dev/null || true)"
        if [[ -n "$NPM_BIN" && ":$PATH:" != *":$NPM_BIN:"* ]]; then
          export PATH="$NPM_BIN:$PATH"
          warn "Added npm global bin ($NPM_BIN) to PATH for this session"
          if [[ "${SC_PERSIST_PATH:-0}" == "1" ]]; then
            local profile
            if [[ -n "${ZSH_VERSION:-}" || "${SHELL:-}" == *"zsh"* ]]; then profile="$HOME/.zprofile"; else profile="$HOME/.bash_profile"; fi
            if ! grep -qs "$NPM_BIN" "$profile"; then
              printf 'export PATH="%s:$PATH"\n' "$NPM_BIN" >> "$profile"
              ok "Persisted npm global bin to $profile"
            fi
          fi
        fi
      fi
    fi
    # Fallback: brew cask
    if ! need_cmd claude && need_cmd brew; then
      warn "Falling back to Homebrew cask for Claude CLI"
      brew install --cask claude-code || warn "brew cask install failed"
    fi
  fi
  need_cmd claude || { err "Claude CLI still not available; MCP install will fail. Install it (npm i -g @anthropic-ai/claude-code) and re-run."; exit 1; }
  ok "Claude CLI ready: $(claude --version 2>/dev/null || echo 'ok')"
}

ensure_claude_shim() {
  # Make claude visible inside pipx/venv-run contexts by shimming to user bins
  local TARGET
  TARGET="$(command -v claude || true)"
  [[ -z "$TARGET" ]] && return 0
  local UB="$($PY -m site --user-base 2>/dev/null || echo "$HOME/Library/Python/3.11")/bin"
  mkdir -p "$UB" "$HOME/.local/bin"
  ln -sf "$TARGET" "$UB/claude"
  ln -sf "$TARGET" "$HOME/.local/bin/claude"
  export PATH="$UB:$HOME/.local/bin:$PATH"
  ok "Claude CLI shimmed to $UB and ~/.local/bin"
}

ensure_uv() {
  # Needed by the "serena" MCP server (expects uv/uvx)
  if need_cmd uvx || need_cmd uv; then ok "uv present"; return 0; fi
  warn "uv not found; installing"
  if need_cmd brew; then brew install uv || true; fi
  if ! need_cmd uvx && ! need_cmd uv; then
    if need_cmd curl; then
      curl -LsSf https://astral.sh/uv/install.sh | sh || warn "uv install script failed"
      hash -r
    else
      warn "curl not available; skipping uv install"
    fi
  fi
  if need_cmd uvx || need_cmd uv; then ok "uv ready"; else warn "uv missing (serena MCP may fail)"; fi
}

show_cli_status() {
  for c in SuperClaude superclaude; do
    if need_cmd "$c"; then
      ok "$c: $("$c" --version 2>/dev/null || echo '?') @ $(command -v "$c")"
    else
      warn "$c not on PATH"
    fi
  done
}

install_or_upgrade_superclaude() {
  local src="${SC_SOURCE:-pypi}"
  if [[ "$src" == "git" ]]; then
    log "Installing from git: $REPO_URL (pipx --force)"
    pipx install --pip-args "--upgrade" --force "git+${REPO_URL}"
  else
    if pipx list --short 2>/dev/null | grep -Eiq '^(superclaude|SuperClaude)\b'; then
      log "Upgrading $PIP_PACKAGE via pipx"
      pipx upgrade "$PIP_PACKAGE" || { warn "upgrade failed; reinstalling"; pipx install --force "$PIP_PACKAGE"; }
    else
      log "Installing $PIP_PACKAGE via pipx"
      pipx install "$PIP_PACKAGE"
    fi
  fi
}

apply_commands() {
  [[ "${SC_NO_APPLY:-0}" == "1" ]] && { warn "Skipping SuperClaude install per SC_NO_APPLY=1"; return 0; }
  if need_cmd SuperClaude; then
    log "Running interactive SuperClaude install (idempotent)"
    SuperClaude install || warn "'SuperClaude install' returned non-zero"
  elif need_cmd superclaude; then
    log "Running via npm wrapper"
    superclaude install || warn "'superclaude install' returned non-zero"
  else
    err "SuperClaude CLI not found after install"; exit 1
  fi
  [[ -d "$HOME/.claude/commands/sc" ]] && ok "Commands present at ~/.claude/commands/sc" || warn "Commands directory missing"
}

maybe_install_npm_wrapper() {
  [[ "${SC_INSTALL_NPM:-0}" != "1" ]] && return 0
  if ! need_cmd npm; then warn "npm not found; skipping npm wrapper"; return 0; fi
  log "Installing/upgrading npm wrapper: $NPM_PACKAGE"
  if npm -g ls "$NPM_PACKAGE" --depth=0 >/dev/null 2>&1; then
    npm -g update "$NPM_PACKAGE" || warn "npm update failed"
  else
    npm -g install "$NPM_PACKAGE" || warn "npm install failed"
  fi
  need_cmd superclaude && ok "npm wrapper: $(superclaude --version 2>/dev/null || echo '?')"
}

maybe_playwright_browsers() {
  # If Playwright is installed, ensure browsers are present
  if need_cmd playwright; then
    warn "Ensuring Playwright browsers are installed"
    playwright install >/dev/null 2>&1 || npx playwright install >/dev/null 2>&1 || true
  fi
}

main() {
  log "=== SuperClaude updater (idempotent) ==="
  ensure_python
  export_user_bin
  persist_path_if_requested
  ensure_pipx
  ensure_node
  ensure_claude_cli
  ensure_claude_shim
  ensure_uv
  show_cli_status
  install_or_upgrade_superclaude
  show_cli_status
  apply_commands
  maybe_install_npm_wrapper
  maybe_playwright_browsers
  ok "Done. Re-run this script anytime to stay updated."
}
main "$@"
