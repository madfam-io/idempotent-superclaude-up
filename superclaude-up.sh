#!/usr/bin/env bash
# superclaude-up.sh
# Version-adaptive, idempotent bootstrap for SuperClaude + Claude CLI.
# - macOS (Intel/ARM) & Linux
# - Ensures: Python3, pipx, uv/uvx, realpath, Node (nvm: 22→20), Claude CLI
# - Installs/updates SuperClaude via pipx (from git by default; PyPI fallback)
# - Scrubs broken "alias claude=..." lines; shims the real CLI into user bins
# - Optional PATH persistence and non-interactive mode
#
# ENV OPTIONS:
#   SC_YES=1                  # auto-confirm (non-interactive where safe)
#   SC_PERSIST_PATH=1         # persist PATH fixes to your shell profile
#   SC_SKIP_NODE=1            # don't manage Node/nvm
#   SC_SOURCE=git|pypi        # where to install SuperClaude from (default git)
#   SC_SKIP_APPLY=1           # skip `SuperClaude install` wizard
#   SC_CLAUDE_INSTALL=auto|npm|brew   # how to install Claude CLI (default auto)
#
# SAFE TO RE-RUN ANYTIME.

set -euo pipefail

# ---------- Pretty logging ----------
if [[ -t 1 ]]; then
  BOLD="$(printf '\033[1m')" ; DIM="$(printf '\033[2m')" ; OFF="$(printf '\033[0m')"
  BLUE="$(printf '\033[34m')" ; GREEN="$(printf '\033[32m')" ; YELLOW="$(printf '\033[33m')" ; RED="$(printf '\033[31m')"
else
  BOLD="" DIM="" OFF="" BLUE="" GREEN="" YELLOW="" RED=""
fi
say(){ printf "%s[info]%s %s\n" "$BLUE" "$OFF" "$*"; }
ok(){  printf "%s[  OK]%s %s\n"  "$GREEN" "$OFF" "$*"; }
wrn(){ printf "%s[warn]%s %s\n" "$YELLOW" "$OFF" "$*"; }
die(){ printf "%s[FAIL]%s %s\n" "$RED" "$OFF" "$*" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1; }

# ---------- OS / Shell info ----------
OS="$(uname -s)"
ARCH="$(uname -m)"
SHELL_NAME="${SHELL##*/}"

# ---------- Global constants ----------
REPO_URL="https://github.com/SuperClaude-Org/SuperClaude_Framework.git"
PIP_PACKAGE="SuperClaude"

# ---------- ask/confirm ----------
ask_yn(){
  local prompt="${1:-Proceed?}" default="${2:-Y}"
  if [[ "${SC_YES:-0}" == "1" ]]; then
    say "$prompt [auto-$default]"
    return 0
  fi
  local ans
  read -r -p "$prompt [Y/n] " ans || true
  [[ -z "$ans" || "${ans^^}" == "Y" || "${ans^^}" == "YES" ]]
}

# ---------- Ensure Python3 ----------
ensure_python(){
  local PY
  if need python3; then PY=python3
  elif need python; then PY=python
  else
    die "Python3 is required. Please install Python 3 and re-run."
  fi
  PY_CMD="$PY"
  ok "Using Python $("$PY" -V 2>/dev/null)"
}

# ---------- Export user bin paths (session + optional persist) ----------
export_user_bins(){
  USER_BASE="$("$PY_CMD" -m site --user-base 2>/dev/null || true)"
  [[ -z "${USER_BASE:-}" ]] && USER_BASE="$HOME/.local"  # fallback
  USER_BIN="$USER_BASE/bin"
  # Always add ~/.local/bin too (pipx default target)
  case ":$PATH:" in
    *":$USER_BIN:"* ) : ;;
    * ) export PATH="$USER_BIN:$PATH" ; wrn "Added $USER_BIN to PATH (session)";;
  esac
  case ":$PATH:" in
    *":$HOME/.local/bin:"* ) : ;;
    * ) export PATH="$HOME/.local/bin:$PATH" ; wrn "Added $HOME/.local/bin to PATH (session)";;
  esac

  if [[ "${SC_PERSIST_PATH:-0}" == "1" ]]; then
    local profile
    if [[ "$SHELL_NAME" == "zsh" ]]; then profile="$HOME/.zprofile"; else profile="$HOME/.bash_profile"; fi
    [[ -f "$profile" ]] || touch "$profile"
    if ! grep -qs 'export PATH="$HOME/.local/bin:$PATH"' "$profile"; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$profile"
    fi
    if ! grep -qs "export PATH=\"$USER_BIN:\$PATH\"" "$profile"; then
      echo "export PATH=\"$USER_BIN:\$PATH\"" >> "$profile"
    fi
    ok "PATH persisted in $profile"
  fi
}

# ---------- Ensure pipx ----------
ensure_pipx(){
  if need pipx; then ok "pipx: $(command -v pipx)"; return; fi
  wrn "pipx not found; installing to user site"
  "$PY_CMD" -m pip install --user -q pipx || die "pipx install failed"
  hash -r || true
  need pipx || die "pipx still not on PATH (open a new shell or enable SC_PERSIST_PATH=1)"
  pipx ensurepath >/dev/null 2>&1 || true
  ok "pipx ready"
}

# ---------- Ensure uv / uvx (Serena MCP needs this) ----------
ensure_uv(){
  if need uvx || need uv; then ok "uv present"; return; fi
  wrn "uv not found; installing"
  if [[ "$OS" == "Darwin" ]] && need brew; then
    brew install uv || wrn "brew install uv failed, trying curl"
  fi
  if ! need uvx && ! need uv; then
    if need curl; then
      curl -LsSf https://astral.sh/uv/install.sh | sh || wrn "uv installer script failed"
      hash -r || true
    else
      wrn "curl not available; cannot auto-install uv"
    fi
  fi
  if need uvx || need uv; then ok "uv ready"; else wrn "uv missing (Serena MCP may not install)"; fi
}

# ---------- Ensure realpath (macOS may lack it; Serena wrapper needs it) ----------
ensure_realpath(){
  if need realpath; then ok "realpath present"; return; fi
  wrn "realpath not found; providing a safe shim"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/realpath" <<'EOS'
#!/usr/bin/env bash
# Minimal realpath shim: resolves a single path argument.
python3 - "$@" <<'PY'
import os, sys
if len(sys.argv) < 2:
    print(os.getcwd())
else:
    print(os.path.realpath(sys.argv[1]))
PY
EOS
  chmod +x "$HOME/.local/bin/realpath"
  hash -r || true
  if need realpath; then ok "realpath shim installed at ~/.local/bin/realpath"; else die "Failed to create realpath shim"; fi
}

# ---------- Ensure curl (for nvm/uv installs on bare hosts) ----------
ensure_curl(){
  need curl && return 0
  wrn "curl is required to bootstrap nvm/uv; please install curl via your package manager and re-run."
}

# ---------- Ensure nvm + Node (prefer 22, fallback 20) ----------
ensure_node(){
  [[ "${SC_SKIP_NODE:-0}" == "1" ]] && { wrn "Skipping Node management per SC_SKIP_NODE=1"; return; }
  ensure_curl

  # Install nvm if needed
  if ! need nvm; then
    wrn "nvm not found; installing to ~/.nvm"
    export NVM_DIR="$HOME/.nvm"
    mkdir -p "$NVM_DIR"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
  else
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
  fi

  need nvm || die "nvm still not available in this shell"

  # Try Node 22 first, fallback to 20
  local want_major=22
  if ! nvm install "$want_major"; then
    wrn "Node $want_major failed; falling back to 20"
    want_major=20
    nvm install "$want_major" || die "Failed to install Node $want_major with nvm"
  fi

  nvm use "$want_major" >/dev/null
  nvm alias default "$want_major" >/dev/null
  ok "Node $(node -v) via nvm"
}

# ---------- Remove broken 'alias claude=...' lines ----------
scrub_claude_aliases(){
  local files=( "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" )
  local removed=0
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*alias[[:space:]]+claude=' "$f"; then
      cp "$f" "$f.bak.$(date +%s)" || true
      # Remove ONLY lines that set alias for claude
      sed -i '' -e '/^[[:space:]]*alias[[:space:]]\+claude=/d' "$f" 2>/dev/null || sed -i -e '/^[[:space:]]*alias[[:space:]]\+claude=/d' "$f"
      removed=1
    fi
  done
  [[ "$removed" == "1" ]] && wrn "Removed stale 'alias claude=…' from your shell config (backups created)"
}

# ---------- Install Claude CLI ----------
install_claude_cli(){
  local mode="${SC_CLAUDE_INSTALL:-auto}"

  if [[ "$mode" == "brew" ]]; then
    if [[ "$OS" == "Darwin" ]] && need brew; then
      say "Installing Claude CLI via Homebrew"
      brew install --cask claude-code || wrn "brew install failed; switching to npm"
      mode="npm"
    else
      wrn "brew unavailable; switching to npm"
      mode="npm"
    fi
  fi

  if [[ "$mode" == "auto" ]]; then
    # Prefer npm (works consistently across macOS/Linux when nvm is present)
    mode="npm"
  fi

  if [[ "$mode" == "npm" ]]; then
    need npm || die "npm not found (did nvm install succeed?)"
    say "Installing/upgrading Claude CLI (@anthropic-ai/claude-code@latest)"
    npm -g install @anthropic-ai/claude-code@latest >/dev/null 2>&1 || npm -g update @anthropic-ai/claude-code@latest || true
  fi

  if ! need claude; then
    die "Claude CLI not found after install"
  fi

  # Shim into user bins to avoid PATH surprises
  local CLAUDE_BIN; CLAUDE_BIN="$(command -v claude)"
  mkdir -p "$HOME/.local/bin" "$USER_BIN"
  ln -sf "$CLAUDE_BIN" "$HOME/.local/bin/claude"
  ln -sf "$CLAUDE_BIN" "$USER_BIN/claude"
  hash -r || true

  ok "Claude CLI: $(claude --version 2>/dev/null)"
}

# ---------- Show tool status ----------
show_status(){
  for c in claude SuperClaude superclaude uvx uv realpath pipx; do
    if need "$c"; then
      case "$c" in
        claude) ok "claude: $(claude --version 2>/dev/null || echo '?') @ $(command -v claude)" ;;
        SuperClaude|superclaude) ok "$c: $($c --version 2>/dev/null || echo '?') @ $(command -v $c)" ;;
        *) ok "$c: $(command -v $c)";;
      esac
    else
      wrn "$c not on PATH"
    fi
  done
}

# ---------- Install / upgrade SuperClaude ----------
install_or_upgrade_superclaude(){
  local src="${SC_SOURCE:-git}"
  if [[ "$src" == "git" ]]; then
    say "Installing SuperClaude (latest) from git: $REPO_URL"
    if ! pipx install --force "git+${REPO_URL}"; then
      wrn "git install failed; falling back to PyPI"
      if pipx list 2>/dev/null | grep -qiE '^package (SuperClaude|superclaude) '; then
        say "Upgrading SuperClaude via pipx"
        pipx upgrade "$PIP_PACKAGE" || pipx install --force "$PIP_PACKAGE"
      else
        say "Installing SuperClaude via pipx"
        pipx install "$PIP_PACKAGE"
      fi
    fi
  else
    if pipx list 2>/dev/null | grep -qiE '^package (SuperClaude|superclaude) '; then
      say "Upgrading SuperClaude via pipx"
      pipx upgrade "$PIP_PACKAGE" || pipx install --force "$PIP_PACKAGE"
    else
      say "Installing SuperClaude via pipx"
      pipx install "$PIP_PACKAGE"
    fi
  fi
}

# ---------- Apply SuperClaude command set (interactive wizard) ----------
apply_superclaude(){
  [[ "${SC_SKIP_APPLY:-0}" == "1" ]] && { wrn "Skipping 'SuperClaude install' per SC_SKIP_APPLY=1"; return; }
  if need SuperClaude; then
    say "Launching SuperClaude interactive installer (idempotent)"
    SuperClaude install || wrn "'SuperClaude install' returned non-zero (you can re-run it anytime)"
  elif need superclaude; then
    say "Launching via 'superclaude' wrapper"
    superclaude install || wrn "'superclaude install' returned non-zero"
  else
    die "SuperClaude CLI not found after install"
  fi
}

# ---------- Post-flight MCP check ----------
mcp_healthcheck(){
  if ! need claude; then wrn "Claude CLI missing; skipping MCP check"; return; fi
  say "Checking MCP server health..."
  claude mcp list || wrn "Claude MCP listing failed (this can be transient)"
}

# ---------- zsh compaudit nudge (do NOT auto-fix) ----------
compaudit_nag(){
  if [[ "$SHELL_NAME" == "zsh" ]] && need compaudit; then
    local bad
    bad="$(compaudit || true)"
    if [[ -n "$bad" ]]; then
      wrn "zsh reports 'insecure directories'. To fix manually:"
      printf "%s\n" "$bad" | sed 's/^/  /'
      echo "Suggested (review before running):"
      echo "  compaudit | xargs -I{} chmod g-w '{}'   # remove group-writable"
      echo "  compaudit | xargs -I{} chown $USER '{}' # ensure owner is you"
      echo "Then restart your shell."
    fi
  fi
}

# ==================== MAIN ====================
main(){
  say "=== SuperClaude updater (version-adaptive, idempotent) ==="

  ensure_python
  export_user_bins
  ensure_pipx
  ensure_uv
  ensure_realpath
  [[ "${SC_SKIP_NODE:-0}" != "1" ]] && ensure_node || wrn "Node management skipped"

  scrub_claude_aliases
  install_claude_cli
  show_status

  install_or_upgrade_superclaude
  show_status

  apply_superclaude
  mcp_healthcheck
  compaudit_nag

  ok "Done. Re-run this script anytime to stay updated."
  echo
  wrn "If you use 'magic' or 'morph' MCP servers, set your API keys:"
  echo "  export TWENTYFIRST_API_KEY=...   # 21st.dev"
  echo "  export MORPH_API_KEY=...         # Morph Fast Apply"
}

main "$@"
