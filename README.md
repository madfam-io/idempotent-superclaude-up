# Idempotent SuperClaude Up 🚀

A **version-adaptive, re-runnable** setup script for getting a great local **Claude Code** + **SuperClaude** + **MCP servers** developer environment on macOS (Intel/ARM) and Linux — including gnarly monorepos.

This repo contains one file you care about:

* `superclaude-up.sh` — the script. Run it as many times as you like.

---

## Why this exists

Setting up Claude Code + MCP servers can be flaky across machines & projects:

* Global vs project **MCP scope** is easy to mix up.
* **Monorepos** with npm workspaces can crash `npx` (hello `EDUPLICATEWORKSPACE`).
* Older macOS versions need **version-compatible Node** + consistent paths.
* Local shells sometimes have bad `alias claude=...` leftovers from older installers.

This script makes the outcome **predictable and repeatable**:

* Installs and configures **Claude CLI**, **SuperClaude**, **Node (nvm)**, **pipx**, **uv/uvx**, and **realpath**.
* Registers **6 MCP servers** in **user scope** (so they show up everywhere) and runs Node MCPs from **\$HOME** to avoid workspace collisions.
* Repairs PATH, cleans broken aliases, fixes `pipx` shims, and adds optional project-level cleanup/merge helpers.

---

## What gets installed / ensured

* **Python 3** (already installed on most systems)
* **pipx** (for SuperClaude)
* **uv/uvx** (for the Serena MCP server)
* **realpath** (shim on macOS if missing)
* **Node via nvm** (prefers Node **22**, falls back to **20** automatically)
* **Claude CLI** (`@anthropic-ai/claude-code`, via npm by default)
* **SuperClaude** (git first, PyPI fallback; with shim repair)
* **MCP servers**:

  * `sequential-thinking` (npx)
  * `context7` (npx)
  * `magic` (npx) — needs `TWENTYFIRST_API_KEY` to actually do UI generation
  * `playwright` (npx)
  * `morphllm-fast-apply` (npx) — optional `MORPH_API_KEY`
  * `serena` (uvx) — **uses `uvx --from git+https://github.com/oraios/serena serena-mcp-server`** (no stray `--`)

---

## Quick start

```bash
# Clone or curl the script, then:
bash superclaude-up.sh
```

Non-interactive with PATH persistence:

```bash
SC_YES=1 SC_PERSIST_PATH=1 bash superclaude-up.sh
```

To validate MCPs in both your home and your current project folder:

```bash
SC_VALIDATE_MCP=1 bash superclaude-up.sh
```

---

## Design choices that save you time

* **User-scope MCPs by default**: They live in `~/.claude.json`, so **every folder** sees the same servers.
* **Force `npx` to run from `$HOME`**: `npx -C "$HOME"` avoids **npm workspace** conflicts (e.g. `EDUPLICATEWORKSPACE`) inside monorepos.
* **Serena via `uvx`**: Uses the correct syntax (`uvx --from … serena-mcp-server`). The common `uvx -- --from` typo is fixed.
* **Version-adaptive Node**: Prefers `22`, falls back to `20` on older OSes.
* **Safe idempotency**: Re-runs won’t break anything; they just update/repair what’s needed.
* **No risky auto-chmod**: We **don’t** auto-fix zsh `compaudit` warnings; we print safe, manual commands instead.

---

## Usage: common flows

### 1) Standard setup

```bash
bash superclaude-up.sh
```

### 2) Non-interactive, persist PATH updates

```bash
SC_YES=1 SC_PERSIST_PATH=1 bash superclaude-up.sh
```

### 3) Register MCPs in **project** scope instead of user

```bash
SC_MCP_SCOPE=project bash superclaude-up.sh
```

> Tip: Project scope is rarely needed; prefer user scope.

### 4) Validate MCPs in `$HOME` vs `$PWD`

```bash
SC_VALIDATE_MCP=1 bash superclaude-up.sh
```

### 5) Your project hides global MCPs? Repair or purge local config

**Merge** user MCPs into the project `.claude.json` (non-destructive):

```bash
SC_REPAIR_PROJECT=1 bash superclaude-up.sh
```

**Purge** project overrides (backs up first):

```bash
SC_PURGE_PROJECT=1 bash superclaude-up.sh
```

---

## Environment variables (advanced)

| Variable            | Default | What it does                                                             |                                     |                                   |
| ------------------- | ------: | ------------------------------------------------------------------------ | ----------------------------------- | --------------------------------- |
| `SC_YES`            |     `0` | Auto-confirm prompts (set `1` for CI/non-interactive).                   |                                     |                                   |
| `SC_PERSIST_PATH`   |     `0` | Append user bins to your shell profile (`.zprofile` or `.bash_profile`). |                                     |                                   |
| `SC_SKIP_NODE`      |     `0` | Skip Node/nvm management.                                                |                                     |                                   |
| `SC_NODE_PREFERRED` |    `22` | Preferred Node major version.                                            |                                     |                                   |
| `SC_NODE_FALLBACK`  |    `20` | Fallback Node major version.                                             |                                     |                                   |
| `SC_CLAUDE_INSTALL` |  `auto` | \`auto                                                                   | npm                                 | brew`– default resolves to`npm\`. |
| `SC_SOURCE`         |   `git` | SuperClaude source: `git` or `pypi`.                                     |                                     |                                   |
| `SC_SKIP_APPLY`     |     `0` | Skip `SuperClaude install` wizard.                                       |                                     |                                   |
| `SC_ADD_MCP`        |     `1` | Register MCP servers.                                                    |                                     |                                   |
| `SC_MCP_SCOPE`      |  `user` | \`user                                                                   | project\` – where to register MCPs. |                                   |
| `SC_VALIDATE_MCP`   |     `0` | Show MCP lists in both `$HOME` and `$PWD`.                               |                                     |                                   |
| `SC_PURGE_PROJECT`  |     `0` | Backup+remove project `.claude.json` / `.claude`.                        |                                     |                                   |
| `SC_REPAIR_PROJECT` |     `0` | Merge user MCPs into project `.claude.json`.                             |                                     |                                   |

---

## API keys (put in your shell rc)

```bash
# 21st.dev Magic MCP (UI component generation)
export TWENTYFIRST_API_KEY="...your key..."

# Morph Fast Apply MCP
export MORPH_API_KEY="...your key..."
```

Then restart your shell, or `source ~/.zshrc` / `source ~/.bashrc`.

---

## Verifying your setup

```bash
which claude
claude --version
claude mcp list
```

You should see all six MCP servers in **any** directory. If `labspace` shows them but `labspace/plinto` doesn’t:

* The folder likely has a **project-level** `.claude.json` that **overrides** your user config.
* Fix it with either:

  * **Merge**: `SC_REPAIR_PROJECT=1 bash superclaude-up.sh`
    (Adds any missing user-scope servers into the project file)
  * **Purge**: `SC_PURGE_PROJECT=1 bash superclaude-up.sh`
    (Backs up and removes local overrides so the user list shines through)

---

## Troubleshooting (greatest hits)

### `npm error code EDUPLICATEWORKSPACE`

* Cause: Running `npx` inside a monorepo with conflicting workspace names.
* Fix in script: MCP registration uses `npx -C "$HOME" …` so Node MCPs **launch from your home**, not your repo.

### Serena fails to parse `--from`

* Symptom: `error: Failed to parse: --from`
* Cause: Using `uvx -- --from …` (extra `--`).
* Fix in script: Uses `uvx --from git+https://github.com/oraios/serena serena-mcp-server`.

### `No MCP servers configured` only in a subfolder

* Cause: Project `.claude.json` overrides your user list with an empty/limited set.
* Fix: `SC_REPAIR_PROJECT=1` (merge) or `SC_PURGE_PROJECT=1` (remove overrides with backup).

### Claude CLI exists but wrong alias takes precedence

* Symptom: `type -a claude` shows an `alias` path that no longer exists.
* Fix in script: Removes `alias claude=…` lines safely from your shell rc files and re-shims the real binary into `~/.local/bin`.

### zsh `compaudit` “insecure directories”

* We **don’t** auto-chmod. Script prints **manual** commands you can review & run.

---

## Uninstall / rollback

* MCP registration:

  * User scope → edit/remove entries in `~/.claude.json`
  * Project scope → edit/remove entries in `<project>/.claude.json`
* SuperClaude venv:

  ```bash
  pipx uninstall superclaude
  rm -f ~/.local/bin/SuperClaude ~/.local/bin/superclaude
  ```
* Claude CLI (npm):

  ```bash
  npm -g uninstall @anthropic-ai/claude-code
  ```
* Node versions / nvm:

  ```bash
  nvm ls
  nvm uninstall <version>
  ```

---

## Security notes

* No elevation (`sudo`) is used.
* We don’t auto-modify permissions on shell directories (zsh `compaudit`); guidance is printed instead.
* MCP registration is explicit and scoped; you control whether it’s `user` or `project`.

---

## Contributing

PRs welcome! Please:

* Keep the script **idempotent**.
* Prefer **user-scope defaults** and **safe fallbacks**.
* Add comments for non-obvious choices (especially around MCPs/monorepos).

---

## License

You choose. If you don’t have one yet, MIT is a good default.

---

## Changelog (highlights)

* **Serena via `uvx`** with correct args (no extra `--`).
* **Monorepo-safe MCP** registration with `npx -C "$HOME"`.
* **User-scope** MCPs by default; optional project scope.
* **Repair/Purge** tools for project config drift.
* Robust **pipx** shim repair and **alias** cleanup.
* Version-adaptive **Node 22 → 20** install.

---

## One last sanity check

```bash
# Show MCPs in home and project
SC_VALIDATE_MCP=1 bash superclaude-up.sh
```

If they differ, use `SC_REPAIR_PROJECT=1` or `SC_PURGE_PROJECT=1` as described above. Happy building!
