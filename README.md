# superclaude-up.sh — Version-adaptive, idempotent bootstrap for SuperClaude + Claude CLI

This script sets up a **reliable SuperClaude + Claude Code CLI environment** on **macOS (Intel/Apple Silicon)** and **Linux**. It’s designed to be **safe to re-run** and **version-adaptive**: you’ll always get the **newest compatible** toolchain for your machine.

---

## What it does

* **Python toolchain**

  * Detects Python 3, sets up `pipx`, and repairs broken venv shims if needed.
* **Node toolchain (nvm)**

  * Installs **Node 22** when possible, otherwise falls back to **Node 20** (customizable).
  * Uses **nvm** so you never compile Node on older macOS versions.
* **Core CLIs**

  * Installs **Claude CLI** (`@anthropic-ai/claude-code`) via npm (or Homebrew if you ask).
  * Installs/updates **SuperClaude** via `pipx` (prefers **git**; falls back to **PyPI**).
* **System helpers**

  * Ensures **uv/uvx** (for Serena MCP) and **realpath** (ships a safe shim on macOS if missing).
* **PATH sanity**

  * Removes stale `alias claude=…` lines from your shell rc.
  * Symlinks the real `claude` + SuperClaude entrypoints into `~/.local/bin`.
  * Optionally **persists PATH** fixes to your shell profile.
* **MCP servers (stable by default)**

  * Registers MCP servers so they **launch from `$HOME`**, avoiding project workspace collisions (`npm ERR! EDUPLICATEWORKSPACE` in monorepos).
  * Installs Serena via `uvx` if available.
* **Safety & idempotency**

  * No `sudo`. No system Python tampering. Re-run anytime.

---

## Supported platforms

* macOS 11+ (Intel & Apple Silicon).
  *Older macOS tiers are handled by using `nvm` binaries rather than Homebrew-built Node.*
* Linux x86\_64/ARM64 with standard userland tools.

---

## Quick start

1. Save the script as `superclaude-up.sh` and make it executable:

   ```bash
   chmod +x superclaude-up.sh
   ```

2. Run it (interactive defaults):

   ```bash
   ./superclaude-up.sh
   ```

3. Prefer **non-interactive**:

   ```bash
   SC_YES=1 SC_PERSIST_PATH=1 SC_SKIP_APPLY=1 ./superclaude-up.sh
   ```

> You can re-run the script anytime to update/repair your setup.

---

## Environment variables (optional)

| Var                 | Default | What it controls                                            |     |                                     |
| ------------------- | ------- | ----------------------------------------------------------- | --- | ----------------------------------- |
| `SC_YES`            | `0`     | `1` = auto-confirm safe prompts.                            |     |                                     |
| `SC_PERSIST_PATH`   | `0`     | `1` = append PATH fixes to your shell profile.              |     |                                     |
| `SC_SKIP_NODE`      | `0`     | `1` = don’t install/manage Node/nvm.                        |     |                                     |
| `SC_NODE_PREFERRED` | `22`    | Preferred Node major.                                       |     |                                     |
| `SC_NODE_FALLBACK`  | `20`    | Fallback Node major.                                        |     |                                     |
| `SC_SOURCE`         | `git`   | Where SuperClaude is installed from (`git` or `pypi`).      |     |                                     |
| `SC_SKIP_APPLY`     | `0`     | `1` = skip `SuperClaude install` wizard.                    |     |                                     |
| `SC_CLAUDE_INSTALL` | `auto`  | \`auto                                                      | npm | brew\` — how to install Claude CLI. |
| `SC_ADD_MCP`        | `1`     | `1` = register MCP servers (from `$HOME`). Set `0` to skip. |     |                                     |

**Examples**

* Headless “just fix it”:

  ```bash
  SC_YES=1 SC_PERSIST_PATH=1 SC_SKIP_APPLY=1 ./superclaude-up.sh
  ```

* Use Homebrew for Claude CLI on macOS:

  ```bash
  SC_CLAUDE_INSTALL=brew ./superclaude-up.sh
  ```

* Skip Node (you already have nvm/Node):

  ```bash
  SC_SKIP_NODE=1 ./superclaude-up.sh
  ```

---

## What gets installed/ensured

* **Python 3** (pre-existing), **pipx**, **uv/uvx**, **realpath** (shim if needed)
* **nvm + Node** (**22** → fallback **20**), **npm**
* **Claude CLI** (`claude`) — shims placed in `~/.local/bin`
* **SuperClaude** (`SuperClaude`/`superclaude`) via `pipx`
* **MCP servers** registered to launch from `$HOME`:

  * `sequential-thinking`
  * `context7`
  * `magic` (requires `TWENTYFIRST_API_KEY` for full functionality)
  * `playwright`
  * `morphllm-fast-apply` (optional `MORPH_API_KEY`)
  * `serena` via `uvx` (if `uvx` available)

> Using `$HOME` as the MCP launch cwd prevents npm workspace name collisions you get inside monorepos.

---

## Verifying your setup

```bash
# Claude CLI exists and reports a version
which claude && claude --version

# SuperClaude exists (either name)
which SuperClaude || which superclaude
SuperClaude --version 2>/dev/null || superclaude --version 2>/dev/null

# MCP servers registered
claude mcp list
```

You should see your MCP servers listed. If you run in a monorepo and previously saw `npm ERR! EDUPLICATEWORKSPACE`, that should be gone now.

---

## API keys you might want

If you selected these MCPs, set their keys in your shell rc (`~/.zshrc`, `~/.bashrc`, etc.):

```bash
export TWENTYFIRST_API_KEY="..."  # for @21st-dev/magic
export MORPH_API_KEY="..."        # for @morph-llm/morph-fast-apply
```

Restart your shell (or `source` your rc file) after setting keys.

---

## Troubleshooting

### “Claude CLI not found” or wrong version

* Remove stale aliases and ensure PATH shims exist:

  ```bash
  grep -R 'alias[[:space:]]\+claude=' ~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc ~/.bash_profile ~/.profile 2>/dev/null
  # If you see any, delete those lines, then:
  SC_YES=1 ./superclaude-up.sh
  ```
* Make sure `~/.local/bin` is in your PATH (the script can persist this for you with `SC_PERSIST_PATH=1`).

### `npm ERR! EDUPLICATEWORKSPACE` when MCP starts

* The script registers MCPs to run from **`$HOME`** with `npx -C "$HOME"` — this avoids the collision.
* Re-register manually if needed:

  ```bash
  claude mcp remove magic 2>/dev/null || true
  claude mcp add magic npx -y -C "$HOME" @21st-dev/magic
  ```

### Serena fails to start

* Make sure `uvx` is installed (the script attempts to install `uv`) and `realpath` exists (shim is provided).
* Re-register:

  ```bash
  claude mcp remove serena 2>/dev/null || true
  claude mcp add serena uvx -- --from git+https://github.com/oraios/serena serena-mcp-server
  ```

### `pipx` shows SuperClaude installed, but `SuperClaude` isn’t on PATH

* The script will try to repair, but you can do it manually:

  ```bash
  pipx uninstall superclaude || true
  pipx install SuperClaude
  ln -sf ~/.local/pipx/venvs/superclaude/bin/SuperClaude ~/.local/bin/SuperClaude
  ln -sf ~/.local/pipx/venvs/superclaude/bin/superclaude ~/.local/bin/superclaude
  hash -r
  ```

### zsh: “insecure directories, run compaudit”

* The script **does not** auto-chmod. Review and fix manually:

  ```bash
  compaudit
  # Suggested (review carefully!)
  compaudit | xargs -I{} chmod g-w '{}'
  compaudit | xargs -I{} chown "$USER" '{}'
  ```

### Old macOS can’t build Node 22 with Homebrew

* That’s expected for Tier-3 macOS. The script uses **nvm** to fetch a compatible binary and falls back to **Node 20** automatically.

---

## Uninstall / Reset

* Remove Claude CLI (npm):

  ```bash
  npm -g uninstall @anthropic-ai/claude-code || true
  ```
* Remove SuperClaude:

  ```bash
  pipx uninstall superclaude || true
  rm -rf ~/.claude
  ```
* Remove MCP registrations:

  ```bash
  claude mcp list | awk '{print $1}' | xargs -I{} claude mcp remove {} || true
  ```
* Clean PATH shims / aliases you added manually.

---

## Design notes & guarantees

* **Idempotent**: safe to run repeatedly; it updates in place.
* **No sudo**: user-local installs only.
* **Version-adaptive**: newest compatible versions for your OS/CPU.
* **Stable MCPs**: always launched from a **clean cwd** to avoid local workspace conflicts.

---

## Common run modes

* **Everything, auto-confirm, persist PATH, skip the interactive wizard**

  ```bash
  SC_YES=1 SC_PERSIST_PATH=1 SC_SKIP_APPLY=1 ./superclaude-up.sh
  ```
* **Use Homebrew for Claude on macOS**

  ```bash
  SC_CLAUDE_INSTALL=brew ./superclaude-up.sh
  ```
* **Pin Node policy**

  ```bash
  SC_NODE_PREFERRED=22 SC_NODE_FALLBACK=20 ./superclaude-up.sh
  ```
* **Skip MCP registration (do it yourself later)**

  ```bash
  SC_ADD_MCP=0 ./superclaude-up.sh
  ```

---

## After install: quick sanity checks

```bash
claude --version
claude mcp list
SuperClaude --version 2>/dev/null || superclaude --version
```

If anything looks off, just re-run:

```bash
SC_YES=1 ./superclaude-up.sh
```

That’s it. Happy building!
