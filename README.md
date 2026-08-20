# alpsync

**Bidirectional folder sync — powered by
[unison](https://github.com/bcpierce003/unison). Runs on macOS and Linux.**

alpsync keeps pairs of folders identical in **both directions** — between
any two machines over SSH (Mac ⇄ Mac, Mac ⇄ Linux, Linux ⇄ Linux) or
between two local paths on the same machine (e.g. a mounted SMB/NAS
share). It wraps a sync method that has proven itself over years of daily
use, and adds a Norton-Commander-style terminal UI, a setup wizard,
dependency management and a clean uninstall — all in a **single bash file**
with no build step.

> **Status: v0.1 (beta).** The core sync workflow is feature-complete and
> covered by an automated test suite. Feedback welcome.

---

## Features

- **True bidirectional sync** — changes propagate in both directions;
  conflicts resolve automatically to the newer file; mass deletions are
  guarded (`-confirmbigdel`)
- **Safe first run** — the first sync of a new pair is a *union merge*:
  files missing on either side are copied across, **nothing is deleted**
- **Two sync modes** — over SSH (Mac ⇄ Linux, Mac ⇄ Mac, Linux ⇄ Linux)
  or between two local paths (SMB/NFS mounts, external drives, …)
- **Norton-Commander-style TUI** — arrow-key menus, boxed summaries,
  two-column pair tables; falls back to plain numbered lists when not
  attached to a terminal
- **Setup wizard** — creates config files interactively; no hand-editing
  required (but configs are plain text and hand-editable)
- **Dependency management** — detects unison/SSH, offers consent-based
  installation (Homebrew, apt, dnf, pacman, zypper, apk); can even install
  unison on the remote host, with a version guard
- **Battle-tested ignore lists** — macOS/Windows/Linux junk and
  permission-locked media libraries are never synced; your own patterns
  can be added per configuration
- **Clean uninstall** — `--uninstall` removes exactly what alpsync added:
  shell alias, configs, unison archives it created, packages it installed
  (each step confirmed, each package opt-in)
- **bash 3.2 compatible** — runs on the stock macOS `/bin/bash`; no
  external UI dependencies

## How the sync works

Each configured folder pair runs as its own
[unison](https://github.com/bcpierce003/unison) job with a proven flag set:

```
unison <local> <remote> \
  -auto -batch -times -perms 0 -rsrc false \
  -prefer newer -confirmbigdel \
  -label "<config>/<pair>"
```

- `-perms 0 -rsrc false` — permission bits and macOS resource forks are
  not compared, so Mac ⇄ Linux and SMB targets work without false diffs
- `-prefer newer` — conflicting files are automatically resolved to the
  newer version
- `-confirmbigdel` — a suddenly emptied replica aborts the pair instead of
  propagating the deletion
- Each pair gets a **unique archive label**, so multiple configs (and other
  unison users on the same machine) never collide

**First run behaviour:** unison has no archive for a new pair yet, so it
merges both sides as a union (copying missing files both ways, deleting
nothing). Every later run is a normal incremental sync.

## Requirements

- macOS or Linux
- `bash` ≥ 3.2 (stock on every Mac; virtually every Linux distro)
- `unison` — optional at first start: alpsync detects it missing and
  offers to install it (with your confirmation)
- For SSH configs: key-based SSH login to the remote host (alpsync tells
  you the two commands if it is not set up yet)

## Installation

No package, no installer — the script directory is the installation:

```sh
git clone https://github.com/77elements/alpsync.git ~/alpsync   # or download & unpack anywhere
cd ~/alpsync
./alpsync.sh                             # first run: dependency check + wizard
```

That's it. During the wizard you are offered an optional shell alias so you
can run `alpsync` from anywhere:

```sh
alias alpsync="/absolute/path/to/alpsync.sh"   # written to ~/.zshrc or ~/.bashrc
```

Configurations (`*.conf`) and the runtime state file (`alpsync.state`)
live in the **same directory** as the script — the folder is
self-contained, easy to back up or move.

## Quick start

1. Run `./alpsync.sh`
2. Choose **‹ New configuration… ›**
3. Answer the wizard: name, SSH yes/no, and your folder mapping, e.g.
   ```
   ~/Documents/projects   /srv/backup/projects
   ~/Music,~/media/Music
   ```
   (separators: spaces, tabs, commas or semicolons; **an empty line
   finishes input**)
4. Optionally add extra ignore patterns — same style, empty line finishes
5. Confirm the summary → the config is written
6. Run it: `./alpsync.sh myconfig.conf` (or select it from the menu)

## CLI reference

| Command | Description |
|---|---|
| `./alpsync.sh` | Show the configuration menu — run one, run all (needs ≥ 2 configs), or create a new one |
| `./alpsync.sh <config>` | Run a configuration — accepts `name`, `name.conf` or a path |
| `./alpsync.sh --uninstall` | Step-by-step removal of everything alpsync added |
| `./alpsync.sh --help` / `-h` | Show help |
| `./alpsync.sh --version` / `-V` | Show version |

Environment: `NO_COLOR=1` disables colored output.

**Exit codes:** `0` success · `1` sync issues · `2` usage/config error ·
`3` dependencies missing or installation declined.

## Configuration file format

Configs are plain `KEY=VALUE` files (`<name>.conf`) next to the script.
Normally created by the wizard, but safe to edit by hand:

```ini
# alpsync configuration
LABEL="home-sync"           # shown during sync (default: file name)
MODE="ssh"                  # "ssh" or "local"

# --- MODE=ssh only ---
REMOTE_HOST="192.168.1.20"
REMOTE_USER="alice"
REMOTE_PORT="22"            # optional, default 22
REMOTE_UNISON=""            # optional; auto-detected on the remote when empty

# --- directory mapping: one pair per line, "local|remote" ---
PAIRS=(
  "~/Documents/knowledge|/srv/sync/knowledge"
  "~/Music|media/Music"
)

# --- optional extra ignore patterns (unison syntax) ---
EXTRA_IGNORES=(
  "Name node_modules"
  "Path secret-stuff"
)
```

**Pair semantics**

- Left side: local path, `~` expands to `$HOME`
- Right side, `MODE=local`: local path (e.g. an SMB mountpoint)
- Right side, `MODE=ssh`: path on the remote host — relative paths
  (including `~/x`, which the wizard normalizes to `x`) are relative to
  the remote user's home; absolute paths start with `/`
- A missing/empty target is never synced into silently — alpsync asks
  (this also catches an unmounted SMB share)

## Ignore patterns

**Always active** (built in, identical for every pair):

- *OS junk:* `.DS_Store`, `._*`, `.Spotlight-V100`, `.Trashes`, `.Trash`,
  `.fseventsd`, `.DocumentRevisions-V100`, `.TemporaryItems`, `.apdisk`,
  `.localized`, `.directory`, `.Trash-*`, `lost+found`, `Thumbs.db`,
  `*.swp`, `*~`
- *macOS media libraries* (permission-locked, huge, platform-specific):
  `*.photoslibrary`, `Photos Library.photoslibrary`, `*.photolibrary`,
  `*.aplibrary`, `Photo Booth Library`, `*.musiclibrary`, `*.itl`,
  `*.itdb`, `iTunes Library.xml`, `iTunes Music Library.xml`

**Deliberately not ignored:** executables and installers (`*.exe`,
`*.dmg`, `*.pkg`, `*.app`, …) — keeping installers safe may be exactly
what you want. Add them per config via `EXTRA_IGNORES` if you prefer.

Patterns use unison syntax: `Name <glob>` matches file names anywhere,
`Path <relpath>` matches paths relative to the sync roots.

## SSH mode specifics

- **Key auth required** — alpsync connects with `BatchMode=yes`; if that
  fails you get a differentiated diagnosis (host unreachable vs. key
  missing) with the exact setup commands
- **unison must exist on both sides with the same X.Y version**
  (e.g. 2.53.x ⇄ 2.53.x). alpsync auto-detects the remote binary; if it
  is missing, it offers to install it on the remote host (consent,
  `ssh -t` — a sudo password prompt appears live on your terminal and is
  never stored). Distro repositories shipping a mismatched version (e.g.
  2.48 when local is 2.53) are refused with guidance instead of
  installing something that cannot sync
- The wizard's **“Test connection now?”** checks all of the above
  immediately (optional — configuring while the remote is offline is fine)

## macOS privacy note (Documents/Desktop/Downloads)

macOS folder protection is granted **per terminal app**. If a sync pair
under `~/Documents`, `~/Desktop` or `~/Downloads` fails with
`Operation not permitted`, alpsync prints an explanation and two fixes:

1. Grant your terminal app access: System Settings → Privacy & Security →
   Files and Folders (or Full Disk Access), then restart the terminal
2. Or grant Full Disk Access to the unison binary itself — works from any
   terminal

Failed pairs simply re-sync as a first-run union on the next run.

## Scheduling example

alpsync is non-interactive once configured (prompts fall back to their
defaults), so cron works:

```cron
# sync every 2 hours, log output
0 */2 * * * cd "$HOME/alpsync" && ./alpsync.sh home-sync.conf </dev/null >> "$HOME/.alpsync.log" 2>&1
```

## Uninstall

```sh
./alpsync.sh --uninstall
```

A 7-step checklist — nothing is removed without confirmation:

1. Shell alias (marker block in `~/.zshrc` / `~/.bashrc` / `~/.bash_profile`)
2. Configuration files (choose one or all)
3. Unison archives **alpsync created** for the selected configs (tracked
   in `alpsync.state`; foreign archives are never touched)
4. Local unison — only if alpsync installed it (opt-in, default No)
5. Local SSH client — only if alpsync installed it (opt-in, default No)
6. Remote unison — only if alpsync installed it (opt-in, default No)
7. The alpsync folder itself — only if it contains exclusively known files

Never touched: Homebrew, sshd, packages you installed yourself, unison
archives belonging to other tools.

## Development

```sh
/bin/bash -n alpsync.sh     # syntax check under bash 3.2 (macOS stock bash)
shellcheck alpsync.sh       # must be clean when shellcheck is installed
tests/run-tests.sh          # full suite: syntax, unit, stubbed SSH/remote
                            # install, wizard e2e, real local-sync e2e,
                            # uninstall e2e (uses throwaway temp dirs only)
```

`tests/reset-state.sh` is a dev-only helper to undo *manual* test runs on
the real system (`--mark` before, `--archives`/`--configs`/`--alias`/
`--dirs` after; it only ever deletes unison archives newer than the time
marker).

## License

[MIT](LICENSE)
