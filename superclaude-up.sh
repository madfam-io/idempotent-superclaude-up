#!/usr/bin/env bash
# superclaude-up.sh
# Version-adaptive, idempotent setup for Claude CLI + SuperClaude + MCP servers.
#
# ✅ macOS (Intel/ARM) & Linux
# ✅ Ensures: Python3, pipx, uv/uvx, realpath, Node (nvm: prefer 22 → fallback 20)
# ✅ Installs/repairs SuperClaude via pipx (git-first, PyPI fallback; venv link fix)
# ✅ Installs Claude CLI (npm by default; can use brew on macOS)
# ✅ Scrubs broken "alias claude=..." and shims the real CLI into user bins
# ✅ Registers MCP servers in *user scope* and launches Node-based servers from $HOME
# ✅ Optional: project-config purge/repair to eliminate per-folder MCP drift
#
# Environment variables (all optional):
#   SC_YES=1                      # auto-confirm (non-interactive where safe)
#   SC_PERSIST_PATH=1             # persist PATH additions to your shell profile
#   SC_SKIP_NODE=1                # skip Node/nvm management
#   SC_NODE_PREFERRED=22          # preferred Node major (default 22)
#   SC_NODE_FALLBACK=20           # fallback Node major (default 20)
#   SC_CLAUDE_INSTALL=auto|npm|brew  # how to install Claude CLI (default auto→npm)
#   SC_SOURCE=git|pypi            # SuperClaude source (default git)
#   SC_SKIP_APPLY=1               # skip 'SuperClaude install' wizard
#   SC_ADD_MCP=1                  # register MCP servers (default 1 = yes)
#   SC_MCP_SCOPE=user|project     # where to register MCPs (default user)
#   SC_VALIDATE_MCP=1             # verify MCP visibility in $HOME and $PWD
#   SC_PURGE_PROJECT=1            # remove local project .claude.json/.claude (backup)
#   SC_REPAIR_PROJECT=1           # merge user MCPs into project config (non-destructive)
#
# SAFE TO RE-RUN ANYTIME.

set -euo pipefail

# ----------------------------- Pretty logging ------------------------------
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

# ----------------------------- OS / Shell info -----------------------------
OS="$(uname -s)"
SHELL_NAME="${SHELL##*/}"

# ----------------------------- Global config ------------------------------
REPO_URL="https://github.com/SuperClaude-Org/SuperClaude_Framework.git"
PIP_PACKAGE="SuperClaude"
SC_NODE_PREFERRED="${SC_NODE_PREFERRED:-22}"
SC_NODE_FALLBACK="${SC_NODE_FALLBACK:-20}"
SC_ADD_MCP="${SC_ADD_MCP:-1}"
SC_MCP_SCOPE="${SC_MCP_SCOPE:-user}"

# ------------------------------ Utilities ---------------------------------
ask_yn(){
  local prompt="${1:-Proceed?}" default="${2:-Y}"
  if [[ "${SC_YES:-0}" == "1" ]]; then
    say "$prompt [auto-$default]"
    return 0
  fi
  local ans; read -r -p "$prompt [Y/n] " ans || true
  [[ -z "$ans" || "${ans^^}" == "Y" || "${ans^^}" == "YES" ]]
}

# BSD vs GNU sed
sedi(){
  if [[ "$OS" == "Darwin" ]]; then sed -E -i '' "$@"; else sed -E -i "$@"; fi
}

# ------------------------------ Python / PATH -----------------------------
PY_CMD="python3"
USER_BASE=""
USER_BIN=""

ensure_python(){
  if need python3; then PY_CMD=python3
  elif need python; then PY_CMD=python
  else die "Python3 is required. Please install Python 3 and re-run."
  fi
  ok "Using $($PY_CMD -V 2>/dev/null)"
}

export_user_bins(){
  USER_BASE="$($PY_CMD -m site --user-base 2>/dev/null || true)"
  [[ -z "$USER_BASE" ]] && USER_BASE="$HOME/.local"
  USER_BIN="$USER_BASE/bin"
  mkdir -p "$USER_BIN" "$HOME/.local/bin"

  case ":$PATH:" in *":$USER_BIN:"*) :;; * ) export PATH="$USER_BIN:$PATH"; wrn "Added $USER_BIN to PATH (session)";; esac
  case ":$PATH:" in *":$HOME/.local/bin:"*) :;; * ) export PATH="$HOME/.local/bin:$PATH"; wrn "Added $HOME/.local/bin to PATH (session)";; esac

  if [[ "${SC_PERSIST_PATH:-0}" == "1" ]]; then
    local profile
    if [[ "$SHELL_NAME" == "zsh" ]]; then profile="$HOME/.zprofile"; else profile="$HOME/.bash_profile"; fi
    [[ -f "$profile" ]] || touch "$profile"
    grep -qs 'export PATH="$HOME/.local/bin:$PATH"' "$profile" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$profile"
    grep -qs "export PATH=\"$USER_BIN:\$PATH\"" "$profile"   || echo "export PATH=\"$USER_BIN:\$PATH\"" >> "$profile"
    ok "PATH persisted in $profile"
  fi
}

# ------------------------------- pipx / uv --------------------------------
ensure_pipx(){
  if need pipx; then ok "pipx: $(command -v pipx)"; return; fi
  wrn "pipx not found; installing to user site"
  "$PY_CMD" -m pip install --user -q pipx || die "pipx install failed"
  hash -r || true
  need pipx || die "pipx still not on PATH (open a new shell or set SC_PERSIST_PATH=1)"
  pipx ensurepath >/dev/null 2>&1 || true
  ok "pipx ready"
}

ensure_uv(){
  if need uvx || need uv; then ok "uv present"; return; fi
  wrn "uv not found; installing"
  if [[ "$OS" == "Darwin" ]] && need brew; then brew install uv || wrn "brew install uv failed, trying curl"; fi
  if ! need uvx && ! need uv; then
    need curl || die "curl is required to fetch uv (and nvm). Please install curl."
    curl -LsSf https://astral.sh/uv/install.sh | sh || wrn "uv installer script failed"
    hash -r || true
  fi
  if need uvx || need uv; then ok "uv ready"; else wrn "uv missing (Serena MCP may not install)"; fi
}

ensure_realpath(){
  if need realpath; then ok "realpath present"; return; fi
  wrn "realpath not found; providing a safe shim"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/realpath" <<'EOS'
#!/usr/bin/env bash
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
  need realpath && ok "realpath shim installed" || die "Failed to create realpath shim"
}

# ------------------------------- Node (nvm) -------------------------------
source_nvm(){ export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; }
ensure_node(){
  [[ "${SC_SKIP_NODE:-0}" == "1" ]] && { wrn "Skipping Node per SC_SKIP_NODE=1"; return; }
  need curl || die "curl is required to bootstrap nvm"
  if ! source_nvm; then
    wrn "nvm not found; installing to ~/.nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    source_nvm || die "Failed to source nvm after install"
  fi
  local major="$SC_NODE_PREFERRED"
  if ! nvm install "$major" >/dev/null 2>&1; then
    wrn "Node $major install failed; trying $SC_NODE_FALLBACK"
    major="$SC_NODE_FALLBACK"
    nvm install "$major" || die "Failed to install Node $major with nvm"
  fi
  nvm use "$major" >/dev/null
  nvm alias default "$major" >/dev/null
  ok "Node $(node -v) via nvm"
}

# ------------------------- Scrub bad 'alias claude' -----------------------
scrub_claude_aliases(){
  local files=( "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" )
  local removed=0
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*alias[[:space:]]+claude=' "$f"; then
      cp -p "$f" "$f.bak.$(date +%s)" || true
      sedi '/^[[:space:]]*alias[[:space:]]\+claude=/d' "$f"
      removed=1
    fi
  done
  [[ "$removed" == "1" ]] && wrn "Removed stale 'alias claude=…' (backups created)"
}

# ------------------------------ Claude CLI --------------------------------
install_claude_cli(){
  local mode="${SC_CLAUDE_INSTALL:-auto}"
  if [[ "$mode" == "brew" ]]; then
    if [[ "$OS" == "Darwin" ]] && need brew; then
      say "Installing Claude CLI via Homebrew"
      brew install --cask claude-code || wrn "brew install failed; switching to npm"
      mode="npm"
    else
      wrn "brew unavailable; switching to npm"; mode="npm"
    fi
  fi
  [[ "$mode" == "auto" ]] && mode="npm"

  if [[ "$mode" == "npm" ]]; then
    need npm || die "npm not found (did nvm install succeed?)"
    say "Installing/upgrading Claude CLI (@anthropic-ai/claude-code@latest)"
    npm -g install @anthropic-ai/claude-code@latest >/dev/null 2>&1 || npm -g update @anthropic-ai/claude-code@latest || true
  fi

  need claude || die "Claude CLI not found after install"

  # Shim to user bins
  local CLAUDE_BIN; CLAUDE_BIN="$(command -v claude)"
  ln -sf "$CLAUDE_BIN" "$HOME/.local/bin/claude"
  [[ -n "${USER_BIN:-}" ]] && ln -sf "$CLAUDE_BIN" "$USER_BIN/claude"
  hash -r || true
  ok "Claude CLI: $(claude --version 2>/dev/null)"
}

# -------------------------- SuperClaude via pipx --------------------------
pipx_ensure_sc_links(){
  local venv="$HOME/.local/pipx/venvs/superclaude"
  [[ -x "$venv/bin/SuperClaude" ]] && ln -sf "$venv/bin/SuperClaude" "$HOME/.local/bin/SuperClaude"
  [[ -x "$venv/bin/superclaude" ]] && ln -sf "$venv/bin/superclaude" "$HOME/.local/bin/superclaude"
}
install_or_upgrade_superclaude(){
  local src="${SC_SOURCE:-git}"
  if [[ "$src" == "git" ]]; then
    say "Installing SuperClaude (git): $REPO_URL"
    if ! pipx install --force "git+${REPO_URL}#egg=${PIP_PACKAGE}" >/dev/null 2>&1; then
      wrn "git install failed; falling back to PyPI"; src="pypi"
    fi
  fi
  if [[ "$src" == "pypi" ]]; then
    if pipx list 2>/dev/null | grep -qiE '^package (SuperClaude|superclaude) '; then
      say "Upgrading SuperClaude via pipx"
      pipx upgrade "$PIP_PACKAGE" || pipx install --force "$PIP_PACKAGE"
    else
      say "Installing SuperClaude via pipx"
      pipx install "$PIP_PACKAGE"
    fi
  fi

  pipx_ensure_sc_links

  if ! command -v SuperClaude >/dev/null 2>&1 && ! command -v superclaude >/dev/null 2>&1; then
    wrn "SuperClaude CLI not on PATH; repairing pipx venv"
    pipx uninstall superclaude >/dev/null 2>&1 || true
    pipx install "$PIP_PACKAGE"
    pipx_ensure_sc_links
  fi

  if command -v SuperClaude >/dev/null 2>&1 || command -v superclaude >/dev/null 2>&1; then
    ok "SuperClaude: $({ SuperClaude --version 2>/dev/null || superclaude --version 2>/dev/null; } | head -n1)"
  else
    die "SuperClaude CLI not found after install"
  fi
}

# ---------------------------- MCP registration ----------------------------
# Key design choices:
#  - Register in *user* scope (when supported) so MCPs are available everywhere.
#  - Force Node-based commands to run from "$HOME" (npx -C "$HOME") to avoid
#    npm workspace conflicts like EDUPLICATEWORKSPACE in monorepos.
#  - Use uvx for Serena without an extra "--" (which broke uvx arg parsing).
register_mcp_servers(){
  [[ "${SC_ADD_MCP}" == "1" ]] || { wrn "Skipping MCP registration (SC_ADD_MCP!=1)"; return; }
  need claude || { wrn "claude not on PATH; skipping MCP registration"; return; }

  # Detect --scope support (newer Claude CLI). If missing, default still lands in ~/.claude.json
  local CLAUDE_SCOPE_ARGS=()
  if claude mcp add --help 2>&1 | grep -q -- "--scope"; then
    if [[ "${SC_MCP_SCOPE}" == "user" ]]; then
      CLAUDE_SCOPE_ARGS=(--scope user)
    elif [[ "${SC_MCP_SCOPE}" == "project" ]]; then
      CLAUDE_SCOPE_ARGS=(--scope project)
    fi
  fi

  # Force NPX to $HOME to avoid monorepo workspace collisions
  local NPX_HOME=(npx -y -C "$HOME")

  say "Registering MCP servers (${SC_MCP_SCOPE} scope; launching from \$HOME)…"
  pushd "$HOME" >/dev/null

  # Node-based servers
  claude mcp add "${CLAUDE_SCOPE_ARGS[@]}" sequential-thinking   "${NPX_HOME[@]}" @modelcontextprotocol/server-sequential-thinking || true
  claude mcp add "${CLAUDE_SCOPE_ARGS[@]}" context7              "${NPX_HOME[@]}" @upstash/context7-mcp || true
  claude mcp add "${CLAUDE_SCOPE_ARGS[@]}" magic                 "${NPX_HOME[@]}" @21st-dev/magic || true
  claude mcp add "${CLAUDE_SCOPE_ARGS[@]}" playwright            "${NPX_HOME[@]}" @playwright/mcp@latest || true
  claude mcp add "${CLAUDE_SCOPE_ARGS[@]}" morphllm-fast-apply   "${NPX_HOME[@]}" @morph-llm/morph-fast-apply || true

  # Serena (uvx) — note: no extra "--" before --from
  if need uvx || need uv; then
    claude mcp add "${CLAUDE_SCOPE_ARGS[@]}" serena uvx --from git+https://github.com/oraios/serena serena-mcp-server || true
  else
    wrn "Skipping Serena MCP (uvx not available)"
  fi

  popd >/dev/null
  ok "MCP servers registered"
}

# --------------------------- Optional project ops -------------------------
# Some repos place a project-level config that *overrides* user MCP servers.
# These helpers let you fix that when needed.

# Remove project-local configs (backs up first). Use with care.
purge_project_configs(){
  [[ "${SC_PURGE_PROJECT:-0}" == "1" ]] || return 0
  say "Purging project-local Claude configs under: $PWD"
  local targets=()
  [[ -f ".claude.json" ]] && targets+=(".claude.json")
  [[ -d ".claude"      ]] && targets+=(".claude")

  if [[ "${#targets[@]}" -eq 0 ]]; then
    ok "No project-local configs found"
    return 0
  fi

  if ask_yn "Backup & remove: ${targets[*]} ?"; then
    for t in "${targets[@]}"; do
      local ts="$(date +%Y%m%d_%H%M%S)"
      mv -f "$t" "${t}.bak.${ts}"
      ok "Backed up $t → ${t}.bak.${ts}"
    done
  else
    wrn "Project purge canceled"
  fi
}

# Merge user MCP servers into project config (non-destructive).
# Requires Python (already ensured). Creates/updates .claude.json in $PWD.
repair_project_configs(){
  [[ "${SC_REPAIR_PROJECT:-0}" == "1" ]] || return 0
  say "Merging user MCP servers into project config (.claude.json)"

  "$PY_CMD" - "$HOME/.claude.json" ".claude.json" <<'PY'
import json, os, sys
user_path, proj_path = sys.argv[1], sys.argv[2]

def load_json(p):
    if not os.path.exists(p): return {}
    with open(p, "r", encoding="utf-8") as f:
        try: return json.load(f)
        except Exception: return {}

user = load_json(user_path)
proj = load_json(proj_path)

user_mcp = (user.get("mcpServers") or {})
proj_mcp = (proj.get("mcpServers") or {})

# Only add missing servers; do not overwrite project-defined ones
merged = dict(proj_mcp)
for name, spec in user_mcp.items():
    if name not in merged:
        merged[name] = spec

if merged != proj_mcp:
    proj["mcpServers"] = merged
    with open(proj_path, "w", encoding="utf-8") as f:
        json.dump(proj, f, indent=2, sort_keys=True)
    print("UPDATED")
else:
    print("NOCHANGE")
PY
  ok "Project config merged (or already in sync)"
}

# ------------------------------- Validation -------------------------------
show_status(){
  for c in claude SuperClaude superclaude uvx uv realpath pipx; do
    if need "$c"; then
      case "$c" in
        claude) ok "claude: $(claude --version 2>/dev/null || echo '?') @ $(command -v claude)";;
        SuperClaude|superclaude) ok "$c: $($c --version 2>/dev/null || echo '?') @ $(command -v $c)";;
        *) ok "$c: $(command -v $c)";;
      esac
    else
      wrn "$c not on PATH"
    fi
  done
}

mcp_healthcheck(){
  need claude || { wrn "Claude CLI missing; skipping MCP check"; return; }
  say "Checking MCP server list (current dir: $PWD)…"
  if ! claude mcp list; then
    wrn "Claude MCP listing failed (transient or no servers configured)"
  fi
}

validate_everywhere(){
  [[ "${SC_VALIDATE_MCP:-0}" == "1" ]] || return 0
  say "Validating MCP visibility in \$HOME and \$PWD…"
  (
    cd "$HOME" && echo -e "\n--- In \$HOME ---" && claude mcp list || true
  )
  (
    echo -e "\n--- In \$PWD ($PWD) ---" && claude mcp list || true
  )
  echo
  wrn "If they differ, a project-level .claude.json may be overriding user servers."
  wrn "Set SC_PURGE_PROJECT=1 to remove local configs or SC_REPAIR_PROJECT=1 to merge."
}

# ----------------------------- Interactive apply --------------------------
apply_superclaude(){
  [[ "${SC_SKIP_APPLY:-0}" == "1" ]] && { wrn "Skipping 'SuperClaude install' (SC_SKIP_APPLY=1)"; return; }
  if need SuperClaude; then
    say "Launching SuperClaude installer (interactive)"
    SuperClaude install || wrn "'SuperClaude install' returned non-zero"
  elif need superclaude; then
    say "Launching superclaude installer (interactive)"
    superclaude install || wrn "'superclaude install' returned non-zero"
  else
    die "SuperClaude CLI not found after install"
  fi
}

# ------------------------------ zsh compaudit -----------------------------
compaudit_nag(){
  if [[ "$SHELL_NAME" == "zsh" ]] && need compaudit; then
    local bad
    bad="$(compaudit || true)"
    if [[ -n "$bad" ]]; then
      wrn "zsh reports 'insecure directories'. To fix manually:"
      printf "%s\n" "$bad" | sed 's/^/  /'
      echo "Suggested (review first):"
      echo "  compaudit | xargs -I{} chmod g-w '{}'   # remove group-writable"
      echo "  compaudit | xargs -I{} chown $USER '{}' # ensure owner is you"
      echo "Then restart your shell."
    fi
  fi
}

# ---------------------------------- MAIN ----------------------------------
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

  register_mcp_servers

  # Optional project-level healing (off by default; enable via env flags)
  purge_project_configs
  repair_project_configs

  mcp_healthcheck
  validate_everywhere

  apply_superclaude
  compaudit_nag

  ok "Done. Re-run this script anytime to stay updated."
  echo
  wrn "If you use 'magic' or 'morph' MCP servers, set your API keys in your shell rc:"
  echo "  export TWENTYFIRST_API_KEY=...   # 21st.dev"
  echo "  export MORPH_API_KEY=...         # Morph Fast Apply"
}

main "$@"
