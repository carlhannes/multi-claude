#!/bin/sh
# Install the multi-claude wrapper as a PATH shim.
#
# Creates ~/.multi-claude/bin/claude as a symlink to the wrapper in this repo
# and prints the PATH line to add. Nothing outside ~/.multi-claude is modified,
# and ~/.local/bin/claude is never touched — that one belongs to `claude update`.

set -u

MC_HOME="$HOME/.multi-claude"
BIN_DIR="$MC_HOME/bin"
SHIM="$BIN_DIR/claude"
REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
WRAPPER="$REPO/claude"

die() { printf 'install: %s\n' "$1" >&2; exit 1; }

[ -f "$WRAPPER" ] || die "cannot find the wrapper at $WRAPPER"

# Find the real claude: the first executable `claude` in PATH that is not the
# shim we are about to create.
real=$(
    printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
        if [ -z "$d" ] || [ ! -x "$d/claude" ] || [ "$d/claude" = "$SHIM" ]; then
            continue
        fi
        printf '%s\n' "$d/claude"
        break
    done
)
if [ -z "$real" ]; then
    die "no 'claude' found in PATH — install Claude Code first (https://claude.com/code)"
fi
real_dir=${real%/claude}

mkdir -p "$BIN_DIR" "$MC_HOME/profiles" || die "cannot create $MC_HOME"
chmod 700 "$MC_HOME" "$MC_HOME/profiles" 2>/dev/null || true

chmod +x "$WRAPPER" 2>/dev/null || true
rm -f "$SHIM"
ln -s "$WRAPPER" "$SHIM" || die "cannot create the symlink $SHIM"

printf 'Installed  %s -> %s\n' "$SHIM" "$WRAPPER"
printf 'Real claude at %s\n\n' "$real"

# Three distinct states, and the messages differ: not in PATH at all, in PATH
# ahead of the real claude, or in PATH behind it (which shadows nothing and is
# the most confusing possible outcome).
path_has() {
    printf '%s\n' "$PATH" | tr ':' '\n' | grep -qxF -- "$1"
}

first_of_shim_or_real=$(
    printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
        if [ "$d" = "$BIN_DIR" ]; then printf 'shim\n'; break; fi
        if [ "$d" = "$real_dir" ]; then printf 'real\n'; break; fi
    done
)

if ! path_has "$BIN_DIR"; then
    case ${SHELL##*/} in
        zsh)  rc="~/.zshrc" ;;
        bash) rc="~/.bashrc" ;;
        *)    rc="your shell startup file" ;;
    esac
    printf 'Add this to %s, then open a new shell:\n\n' "$rc"
    printf '    export PATH="%s:$PATH"\n\n' "$BIN_DIR"
    printf 'It has to come after anything that adds %s to your PATH.\n' "$real_dir"
    printf 'Then check it took effect:  command -v claude\n'
    printf 'That should print %s\n' "$SHIM"
elif [ "$first_of_shim_or_real" = shim ]; then
    printf 'PATH is already set up. Try:  claude profile list\n'
else
    printf 'PATH problem: %s comes before %s, so the wrapper will never run.\n' "$real_dir" "$BIN_DIR"
    printf 'Move this line after whatever adds %s to your PATH:\n\n' "$real_dir"
    printf '    export PATH="%s:$PATH"\n' "$BIN_DIR"
fi
