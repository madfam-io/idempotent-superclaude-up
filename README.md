# superclaude-up.sh — README

An idempotent, “works-from-a-clean-machine” bootstrap script for **SuperClaude**.

It installs/updates the SuperClaude CLI and framework, wires in required system dependencies, and runs the interactive installer to lay down commands, modes, agents, and MCP servers. Safe to re-run anytime.

---

## What it does (in order)

1. **Ensures Python 3** is available (uses Homebrew on macOS if needed).
2. **Fixes PATH for user installs** (adds your Python *user base* bin for this session; optional persistent fix).
3. **Ensures `pipx`** (preferred isolation for Python CLIs).
4. **Ensures Node/npm (optional)** if you install the Claude CLI via npm.
5. **Ensures the Anthropic Claude CLI (`claude`)** via npm or Homebrew (configurable).
6. **Shims `claude` into user bins** so it’s visible inside `pipx`/venv contexts (fixes “Claude CLI not found” during MCP setup).
7. **Ensures `uv`/`uvx`** (required by the `serena` MCP server).
8. **Installs/updates SuperClaude** via `pipx` (PyPI by default, or GitHub).
9. **Runs `SuperClaude install`** (interactive, idempotent).
10. **(Optional) Installs the npm wrapper** `@bifrost_inc/superclaude`.
11. **(Optional) Installs Playwright browsers** if Playwright is present.

---

## Requirements

* macOS or Linux shell (tested with **zsh** and **bash**)
* Internet access
* One of:

  * **Homebrew** (recommended on macOS), or
  * existing **Python 3** and **npm** for CLI paths

> The script will try to install what’s missing (Python via Homebrew, `pipx` via `pip`, Claude CLI via npm/brew, `uv` via curl/brew).

---

## Quick start

1. Save the script (overwrite if it already exists):

```bash
cat > superclaude-up.sh <<'BASH'
# (paste the script contents you have)
BASH
chmod +x superclaude-up.sh
```

2. Run it (interactive install by default):

```bash
bash superclaude-up.sh
```

3. In the **installer UI**:

* **Stage 1 (MCP servers):** pick your servers (e.g., `1,2,3,4,5,6`).
* **Stage 2 (Framework components):** `all` or a subset (at least `core`, `modes`, `commands`).

---

## Environment options

Set as prefixes when running the script:

* `SC_SOURCE=pypi|git`
  Install SuperClaude from **PyPI** (default) or directly from **GitHub**.

* `SC_INSTALL_NPM=1`
  Also install/update the **npm wrapper** (`@bifrost_inc/superclaude`).

* `SC_PERSIST_PATH=1`
  Append PATH fixes to your shell profile (`~/.zprofile` or `~/.bash_profile`).

* `SC_NO_APPLY=1`
  **Skip** running the interactive `SuperClaude install` (only prep deps & CLI).

* `SC_CLAUDE_INSTALL=npm|brew`
  Force how the **Claude CLI** is installed (defaults to npm if available, else brew).

### Examples

```bash
# Typical first run: persist PATH and install npm wrapper too
SC_PERSIST_PATH=1 SC_INSTALL_NPM=1 bash superclaude-up.sh

# Install from GitHub instead of PyPI
SC_SOURCE=git bash superclaude-up.sh

# Prepare everything but skip the interactive installer
SC_NO_APPLY=1 bash superclaude-up.sh

# Force Claude CLI install via Homebrew cask
SC_CLAUDE_INSTALL=brew bash superclaude-up.sh
```

---

## After running: sanity checks

```bash
# SuperClaude and wrapper
SuperClaude --version
superclaude --version  # if you installed the npm wrapper

# Commands laid down?
ls -1 ~/.claude/commands/sc | head

# Claude CLI & MCP
which claude && claude --version
claude mcp --help  # should print usage

# (Optional) ensure Playwright has browsers
playwright install || npx playwright install
```

If you use these MCP servers, add keys and re-run Stage 1 for that server only:

```bash
# magic / 21st.dev
echo 'export TWENTYFIRST_API_KEY="your_21st_dev_key"' >> ~/.zprofile
# morph fast-apply
echo 'export MORPH_API_KEY="your_morph_key"' >> ~/.zprofile
source ~/.zprofile
SuperClaude install   # Stage 1: select only the server you want to refresh
```

---

## Troubleshooting

**“Claude CLI not found – required for MCP server management”**

* The script installs `claude` and **shims it** into user bins, but if corporate path rules or shells differ:

  ```bash
  # Make sure claude is reachable
  which claude || npm i -g @anthropic-ai/claude-code
  # Shim into user bins pipx can see
  UB="$(python3 -m site --user-base)/bin"; mkdir -p "$UB" "$HOME/.local/bin"
  ln -sf "$(command -v claude)" "$UB/claude"
  ln -sf "$(command -v claude)" "$HOME/.local/bin/claude"
  export PATH="$UB:$HOME/.local/bin:$PATH"
  ```

  Then re-run `SuperClaude install` and select only MCP servers.

**`pipx` installed but “not on PATH”**

* Add user-base bin:

  ```bash
  echo 'export PATH="$(python3 -m site --user-base)/bin:$HOME/.local/bin:$PATH"' >> ~/.zprofile
  exec zsh -l
  ```

**`serena` server fails with `uvx` not found**

* Install `uv`:

  ```bash
  brew install uv || curl -LsSf https://astral.sh/uv/install.sh | sh
  exec zsh -l
  SuperClaude install  # Stage 1: select "serena" only
  ```

**Playwright says browsers missing**

```bash
npm i -g playwright || true
playwright install || npx playwright install
```

**npm global bin not on PATH**

```bash
echo 'export PATH="$(npm bin -g):$PATH"' >> ~/.zprofile
exec zsh -l
```

---

## What gets installed & where

* **SuperClaude CLI** (Python): `pipx` venv at `~/.local/pipx/venvs/superclaude`, entrypoints in `~/.local/bin/`
* **SuperClaude framework files**: `~/.claude/` (core, modes, commands, agents, docs)
* **Claude CLI**: npm global bin (e.g., `/usr/local/bin` or `$NPM_PREFIX/bin`) or Homebrew cask
* **MCP servers**: registered for Claude Code (managed by `claude mcp …`)
* **Shims**: `claude` symlinks in your Python user-base bin and `~/.local/bin`

> The SuperClaude installer itself backs up `~/.claude` inside `~/.claude/backups/…` when updating.

---

## Uninstall / cleanup (optional)

* Remove SuperClaude (pipx):

  ```bash
  pipx uninstall SuperClaude
  ```
* Remove framework files:

  ```bash
  rm -rf ~/.claude
  ```
* Remove Claude CLI:

  ```bash
  npm -g uninstall @anthropic-ai/claude-code || brew uninstall --cask claude-code
  ```
* Remove shims:

  ```bash
  rm -f "$(python3 -m site --user-base)/bin/claude" "$HOME/.local/bin/claude"
  ```

---

## FAQ

**Is it safe to run multiple times?**
Yes. The script is **idempotent**; it upgrades if present and installs if missing.

**Do I have to install from PyPI?**
No. Set `SC_SOURCE=git` to install directly from the upstream repository.

**Why do we “shim” `claude`?**
The SuperClaude installer runs from a `pipx` environment; shimming ensures that `claude` is resolvable in that context, avoiding the “Claude CLI not found” error during MCP setup.

**Can I skip the interactive installer?**
Yes. Use `SC_NO_APPLY=1` to only prep dependencies and the CLI, then run `SuperClaude install` later.
