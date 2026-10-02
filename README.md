# multi-claude

One Claude Code account per working directory.

Claude Code holds one logged-in account per config directory, so juggling a work org and a
personal subscription normally means logging out and back in — losing session history each
time. `multi-claude` is a small POSIX shell wrapper that shadows `claude` in your `PATH`,
works out which account the current directory belongs to, points `CLAUDE_CONFIG_DIR` at that
profile, and hands over to the real `claude`.

```
cd ~/work/api      && claude   # work account
cd ~/side-project  && claude   # personal account
```

The first time you run `claude` somewhere new it asks which account to use and remembers the
answer. Nothing else changes: login, updates, and every flag are still the real `claude`.

No dependencies beyond what ships with macOS and Ubuntu LTS.

## Install

```sh
git clone <this repo> ~/src/multi-claude
cd ~/src/multi-claude
./install.sh
```

The installer symlinks the wrapper into `~/.multi-claude/bin/` and prints the one `PATH` line
to add to your shell startup file. It edits none of your files, and it never touches
`~/.local/bin/claude` — that symlink belongs to `claude update`. Because the shim is a symlink
into the clone, `git pull` updates the tool in place.

### Try it in one shell first

You do not have to edit your shell config to evaluate this. One `export` in a throwaway shell
is a complete trial, and closing the shell reverts it:

```sh
export PATH="$HOME/.multi-claude/bin:$PATH"
command -v claude    # should print ~/.multi-claude/bin/claude
```

Every `claude` in that shell now goes through the wrapper. Nothing persists except profiles you
explicitly create, and `claude profile rm NAME` removes those.

**Test from a plain terminal, not from inside a Claude Code session.** A nested session sets
`CLAUDECODE`, which trips the nested-session passthrough described below, so the wrapper
deliberately does nothing — which looks exactly like a broken install.

### Make it permanent

Add the same line to your shell startup file. It must come *after* anything that adds the real
`claude` to your `PATH`, or the wrapper is shadowed instead of shadowing. Re-run `./install.sh`
at any time to check; it reports which of the two currently wins.

## Usage

```
claude profile              pick the profile for this directory
claude profile list         show profiles, accounts and directory mappings
claude profile use NAME     map this directory to NAME
claude profile unset        drop this directory's mapping
claude profile new NAME     create a profile
claude profile rm NAME      delete a profile
```

Everything else passes straight through to the real `claude`.

```sh
claude profile new personal     # create it
cd ~/side-project && claude     # picker appears; choose personal; /login once
cd ~/side-project/packages/ui
claude                          # subdirectories inherit the mapping
```

For a one-off, without saving anything:

```sh
CLAUDE_PROFILE=personal claude
```

## How it works

Claude Code's `CLAUDE_CONFIG_DIR` environment variable relocates everything it stores —
settings, `.claude.json`, credentials, and session transcripts. Give each account its own
directory and each gets its own independent login. The wrapper's job is deciding which
directory to name — and then linking the session history back together, below.

| Path | Purpose |
| --- | --- |
| `claude` | The wrapper. The whole tool. |
| `install.sh` | Creates the shim symlink and checks `PATH` ordering. |
| `test.sh` | Behavioural tests. Hermetic — see [Tests](#tests). |
| `~/.multi-claude/bin/claude` | The shim: a symlink to the wrapper, first in `PATH`. |
| `~/.multi-claude/profiles/NAME/` | One `CLAUDE_CONFIG_DIR` per profile, mode `0700`, with `projects/` and `file-history/` linked into `~/.claude`. |
| `~/.claude/projects/` | Session transcripts and per-directory memory. Shared by every profile. |
| `~/.claude/file-history/` | `/rewind` checkpoints. Shared by every profile. |
| `~/.multi-claude/dirmap` | Tab-separated `directory` → `profile` records. |
| `~/.multi-claude/default-removed` | Marker: the `~/.claude` profile was deleted. Remove it to restore. |

Resolution stops at the first of these that applies:

1. **`claude profile ...`** — handled by the wrapper; never forwarded.
2. **`CLAUDECODE` is set** — a nested session. Passed through with the environment untouched,
   so subagents and background tasks stay on their parent's account.
3. **`CLAUDE_CONFIG_DIR` is already set** — an explicit choice outranks any mapping. Note that
   exporting it from your shell startup file disables per-directory switching entirely;
   `claude profile list` says so when it sees this.
4. **`CLAUDE_PROFILE` is set** — the one-off override.
5. **A `dirmap` entry** for the current directory or its nearest mapped ancestor.
6. **No mapping** — the picker appears if stdin is a terminal. Otherwise the `default` profile
   is used and a note goes to stderr, so pipes, scripts, and CI behave exactly as they did
   before installing this and can never block on a prompt. If `default` has been deleted, a
   non-interactive run exits with an error naming the fix instead of guessing an account.

### Why `default` means "unset"

The `default` profile is your existing `~/.claude`, and selecting it works by *unsetting*
`CLAUDE_CONFIG_DIR` rather than by setting it to `~/.claude`. Those are not equivalent.

On macOS, Claude Code derives its Keychain entry name from the config directory, appending a
hash of the path — and it omits that suffix only when `CLAUDE_CONFIG_DIR` is unset. Setting the
variable to `~/.claude` therefore looks for a *different* Keychain entry, and your existing
login appears to have vanished. Unsetting it means installing this tool requires no migration
and no re-login.

This is also what makes profiles genuinely isolated on macOS, where credentials live in the
Keychain rather than in a file. The wrapper never touches the Keychain itself: deleting a
profile runs Claude Code's own `auth logout` against that profile.

### Deleting `default`

Once another profile exists, `claude profile rm default` works like deleting any profile: it
logs `~/.claude` out, drops its directory mappings so those folders ask again, and stops
offering it. What differs is what stays: `~/.claude` itself, because it holds the session
history every profile shares, and its `settings.json` and `~/.claude.json`, which become inert.
A marker file, `~/.multi-claude/default-removed`, records the deletion; delete the marker to
offer `~/.claude` again, or log into a new named profile instead.

There is deliberately no replacement fallback. A mapping always names a concrete profile, so
nothing can change which account a folder uses behind your back.

### Session history is shared

Two directories inside a profile are symlinks into `~/.claude` rather than real directories:
`projects/`, which holds the session transcripts that `claude --resume` lists (and the
per-directory memory Claude Code keeps beside them), and `file-history/`, which holds the
`/rewind` checkpoints. The wrapper creates the links when a profile is made and re-creates
them on launch if they go missing, so every profile sees one pool of sessions for the machine
and `--resume` shows a conversation no matter which account recorded it.

Everything else stays per profile: the login, `.claude.json` (account identity and per-project
trust), `settings.json`, plugins, skills, and `history.jsonl` — the arrow-up prompt recall,
which Claude Code refuses to read through a symlink, so it cannot join the shared set.

Claude Code builds these paths with a plain join and applies its symlink checks to the files
inside, so a linked directory is transparent to it. That was verified by reading the binary
(2.1.283), not from documentation — see [Limitations](#limitations).

### Sharing history from an older profile

A profile created before history was shared has a real `projects/` directory with its own
transcripts. The wrapper leaves such a directory alone and says so on every launch, because
merging is a judgment call: session ids are unique, so transcripts never collide, but two
profiles may both hold a `memory/` for the same folder. Move everything across, then merge any
leftover `memory/` by hand:

```sh
P=~/.multi-claude/profiles/NAME
S=~/.claude/projects
for d in "$P"/projects/*/; do
    slug=$(basename "$d")
    mkdir -p "$S/$slug"
    for x in "$d"*; do
        # both profiles remember this folder: merge memory/ by hand
        [ "$(basename "$x")" = memory ] && [ -e "$S/$slug/memory" ] && continue
        mv "$x" "$S/$slug/"
    done
done
find "$P/projects" -type f          # anything printed needs a by-hand merge into $S
mkdir -p ~/.claude/file-history && mv "$P"/file-history/* ~/.claude/file-history/
rm -rf "$P/projects" "$P/file-history"   # once nothing you care about remains
```

The next `claude` in a directory mapped to that profile links both directories.

## Developing

To run the wrapper straight from a clone without installing anything, put the repo itself on
`PATH` — the repo root holds the executable `claude`, so that is all it takes, and your edits
are live immediately:

```sh
export PATH="$PWD:$PATH"
```

Run that from the repo root. `$PWD` expands at that moment, so it keeps working after you `cd`
away; confirm with `command -v claude`. Avoid `.:$PATH`, which would let any directory you
visit supply its own `claude`. Note this acts on your real profiles in `~/.multi-claude`, so
use the tests below for anything you would rather not do to real state.

## Tests

```sh
./test.sh                # or: ./test.sh /bin/dash
```

Every check runs the wrapper with `HOME` pointed at a temp directory and a stub `claude` first
on `PATH`, so the suite never reads or writes a real profile, credential, or binary. It is safe
to run at any time and cleans up after itself.

## Limitations

- **`claude daemon service install` needs the default profile.** Claude Code refuses a
  non-default config directory there, because the launchd/systemd unit is a per-user
  singleton.
- **Profiles share session history and nothing else.** Settings, skills, agents, MCP servers,
  and prompt recall do not carry across; a new profile is otherwise a clean slate. Per-directory
  memory lives inside `projects/`, so it is shared too — what Claude remembers about a folder
  does not depend on which account is billed.
- **A linked `projects/` is not a documented Claude Code configuration.** It works because the
  binary joins the path and only refuses symlinks at the file level (verified on 2.1.283). If a
  future update stops following it, remove the link from that profile and it falls back to
  isolated history; nothing is lost either way.
- **History cleanup is shared.** Claude Code's transcript retention (`cleanupPeriodDays`) and
  its history purge act on the shared pool whichever profile runs them.
- **Per-project trust is per-profile**, since `.claude.json` moves into the profile directory.
  Expect to re-approve a directory the first time you use it under a new profile.
- **`claude profile` could collide** if Claude Code ever gains a `profile` subcommand of its
  own. The fix would be renaming ours.
- **Bypassing the wrapper re-creates a `default` login.** With `default` deleted, running
  `~/.local/bin/claude` directly still uses `~/.claude` and will offer to log in there.
- **Linux is untested.** The scripts are POSIX-only and Claude Code documents storing
  credentials at `$CLAUDE_CONFIG_DIR/.credentials.json` on Linux, so it should work — but it
  has only been exercised on macOS.

## Uninstall

```sh
rm -rf ~/.multi-claude          # shim, profiles, and mappings
```

Then drop the `PATH` line from your shell startup file. `~/.claude` is never touched — a
profile directory only holds *symlinks* into it, which `rm -rf` removes without following — so
your original account and every session transcript are exactly where they were.

Removing `~/.multi-claude` orphans any per-profile credentials macOS holds in the Keychain. To
avoid that, `claude profile rm NAME` each profile first — that logs out properly.
