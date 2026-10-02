#!/bin/sh
# Behavioural tests for the multi-claude wrapper.
#
# Hermetic by construction, so this is safe to run at any time: every check runs
# the wrapper with HOME pointed at a temp directory (the wrapper derives its
# profile paths from $HOME at runtime) and with a stub `claude` on PATH (the
# wrapper finds the real one by walking PATH). No real profile, credential or
# binary is read or written.
#
# Usage: ./test.sh [shell]        e.g. ./test.sh /bin/dash

set -u

SH=${1:-/bin/sh}
REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
WRAPPER="$REPO/claude"
[ -f "$WRAPPER" ] || { printf 'cannot find %s\n' "$WRAPPER" >&2; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/stub" "$TMP/home" "$TMP/proj/deep/nested" "$TMP/elsewhere"
# The stub also logs every call, because `rm` discards the output of its logout.
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/sh
line=$(printf 'STUB config_dir=[%s] args=[%s]' "${CLAUDE_CONFIG_DIR-<UNSET>}" "$*")
printf '%s\n' "$line" | tee -a "__LOG__"
STUB
sed "s|__LOG__|$TMP/calls.log|" "$TMP/stub/claude" > "$TMP/stub/claude.tmp" && mv "$TMP/stub/claude.tmp" "$TMP/stub/claude"
chmod +x "$TMP/stub/claude"

# The picker sits behind `[ -t 0 ]` and macOS `script` mangles piped stdin, so
# its *selection* logic is exercised against a copy with that one predicate
# neutralised. The gate itself is tested on the real script (see "no tty" cases).
PICKER="$TMP/picker-claude"
sed 's/\[ -t 0 \]/true/g' "$WRAPPER" > "$PICKER"
chmod +x "$PICKER"

pass=0
fail=0

check() { # description, expected substring, actual
    if printf '%s' "$3" | grep -qF -- "$2"; then
        pass=$((pass + 1))
        printf '  ok   %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n         wanted substring: %s\n         got:              %s\n' "$1" "$2" "$3"
    fi
}

check_eq() { # description, expected, actual
    if [ "$3" = "$2" ]; then
        pass=$((pass + 1))
        printf '  ok   %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n         wanted: %s\n         got:    %s\n' "$1" "$2" "$3"
    fi
}

check_absent() { # description, forbidden substring, actual
    if printf '%s' "$3" | grep -qF -- "$2"; then
        fail=$((fail + 1))
        printf '  FAIL %s\n         unwanted substring: %s\n         got:                %s\n' "$1" "$2" "$3"
    else
        pass=$((pass + 1))
        printf '  ok   %s\n' "$1"
    fi
}

# Run the wrapper in DIR with a clean environment.
mc() {
    _dir=$1
    shift
    (
        cd "$_dir" || exit 1
        unset CLAUDECODE CLAUDE_CONFIG_DIR CLAUDE_PROFILE
        HOME="$TMP/home"
        PATH="$TMP/stub:/usr/bin:/bin"
        export HOME PATH
        "$SH" "$WRAPPER" "$@" 2>&1
    )
}

# Same, but driving the picker copy with stdin from a here-doc-ish string.
mc_pick() {
    _dir=$1
    _input=$2
    shift 2
    (
        cd "$_dir" || exit 1
        unset CLAUDECODE CLAUDE_CONFIG_DIR CLAUDE_PROFILE
        HOME="$TMP/home"
        PATH="$TMP/stub:/usr/bin:/bin"
        export HOME PATH
        printf '%s' "$_input" | "$SH" "$PICKER" "$@" 2>&1
    )
}

reset_state() { rm -rf "$TMP/home/.multi-claude" "$TMP/home/.claude" "$TMP/calls.log"; }

dirmap_lines() {
    if [ -f "$TMP/home/.multi-claude/dirmap" ]; then
        awk 'END { print NR }' "$TMP/home/.multi-claude/dirmap"
    else
        printf '0\n'
    fi
}

printf 'multi-claude tests (shell: %s)\n\n' "$SH"

# --- resolution order -------------------------------------------------------
printf 'resolution order\n'
reset_state
mc "$TMP/proj" profile new work >/dev/null 2>&1
mc "$TMP/proj" profile use work >/dev/null 2>&1

# A nested session must keep its parent's environment even when a mapping exists.
out=$(
    cd "$TMP/proj" || exit 1
    unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE
    HOME="$TMP/home"; PATH="$TMP/stub:/usr/bin:/bin"; CLAUDECODE=1
    export HOME PATH CLAUDECODE
    "$SH" "$WRAPPER" --version 2>&1
)
check "nested session ignores the mapping" "config_dir=[<UNSET>]" "$out"

# An explicit CLAUDE_CONFIG_DIR outranks any mapping.
out=$(
    cd "$TMP/proj" || exit 1
    unset CLAUDECODE CLAUDE_PROFILE
    HOME="$TMP/home"; PATH="$TMP/stub:/usr/bin:/bin"; CLAUDE_CONFIG_DIR=/explicit/dir
    export HOME PATH CLAUDE_CONFIG_DIR
    "$SH" "$WRAPPER" --version 2>&1
)
check "pre-set CLAUDE_CONFIG_DIR wins" "config_dir=[/explicit/dir]" "$out"

# CLAUDE_PROFILE outranks the mapping.
mc "$TMP/proj" profile new other >/dev/null 2>&1
out=$(
    cd "$TMP/proj" || exit 1
    unset CLAUDECODE CLAUDE_CONFIG_DIR
    HOME="$TMP/home"; PATH="$TMP/stub:/usr/bin:/bin"; CLAUDE_PROFILE=other
    export HOME PATH CLAUDE_PROFILE
    "$SH" "$WRAPPER" --version 2>&1
)
check "CLAUDE_PROFILE overrides the mapping" "profiles/other]" "$out"

out=$(mc "$TMP/elsewhere" --version)
check "unmapped dir falls back to default"  "config_dir=[<UNSET>]" "$out"
check "unmapped dir says so on stderr"      "using default"        "$out"

# --- mapping ----------------------------------------------------------------
printf '\nmapping\n'
reset_state
mc "$TMP/proj" profile new work >/dev/null 2>&1
out=$(mc "$TMP/proj" profile use work)
check "use records a mapping" "-> work" "$out"

out=$(mc "$TMP/proj/deep/nested" --version)
check "nested subdir inherits via ancestor walk" "profiles/work]" "$out"

out=$(mc "$TMP/elsewhere" --version)
check "sibling dir does not inherit" "config_dir=[<UNSET>]" "$out"

mc "$TMP/proj" profile use work >/dev/null 2>&1
mc "$TMP/proj" profile use work >/dev/null 2>&1
check_eq "re-mapping replaces, never duplicates" "1" "$(dirmap_lines)"

out=$(mc "$TMP/proj" profile unset)
check "unset removes the mapping" "removed the mapping" "$out"
check_eq "dirmap is empty after unset" "0" "$(dirmap_lines)"

# --- safety guards ----------------------------------------------------------
# Regression tests for a traversal bug: `rm` once accepted "../name", so
# $PROFILES_DIR/../name resolved outside the profiles tree and was rm -rf'd.
printf '\nsafety guards\n'
reset_state
mc "$TMP/proj" profile new work >/dev/null 2>&1
mkdir -p "$TMP/home/.multi-claude/CANARY"
: > "$TMP/home/.multi-claude/CANARY/precious"

out=$(mc "$TMP/proj" profile rm ../CANARY </dev/null)
check "rm rejects a traversal name" "invalid profile name" "$out"
check_eq "the canary survived" "yes" "$(test -f "$TMP/home/.multi-claude/CANARY/precious" && echo yes || echo GONE)"

# Without a tty, `rm` stops at the confirmation before reaching rm -rf, so the
# canary check above cannot prove much on its own. Re-run it through the copy
# with the gate neutralised and the confirmation answered: this is the check
# that actually proves a traversal name deletes nothing.
out=$(mc_pick "$TMP/proj" 'y
' profile rm ../CANARY)
check "rm past the confirmation still rejects traversal" "invalid profile name" "$out"
check_eq "canary survived a CONFIRMED traversal rm" "yes" "$(test -f "$TMP/home/.multi-claude/CANARY/precious" && echo yes || echo GONE)"

out=$(mc "$TMP/proj" profile use ../CANARY)
check "use rejects a traversal name" "invalid profile name" "$out"

out=$(
    cd "$TMP/proj" || exit 1
    unset CLAUDECODE CLAUDE_CONFIG_DIR
    HOME="$TMP/home"; PATH="$TMP/stub:/usr/bin:/bin"; CLAUDE_PROFILE=../CANARY
    export HOME PATH CLAUDE_PROFILE
    "$SH" "$WRAPPER" --version 2>&1
)
check "CLAUDE_PROFILE rejects a traversal name" "does not exist" "$out"

out=$(mc "$TMP/elsewhere" profile rm default </dev/null)
check "rm default refuses without a tty" "interactive confirmation" "$out"

out=$(mc "$TMP/proj" profile rm work </dev/null)
check "rm refuses without a tty" "interactive confirmation" "$out"

out=$(mc "$TMP/proj" profile </dev/null)
check "picker refuses without a tty" "not a terminal" "$out"

out=$(mc "$TMP/proj" profile new 'bad name')
check "new rejects a name with a space" "invalid profile name" "$out"

out=$(mc "$TMP/proj" profile new default)
check "new refuses the reserved name" "reserved" "$out"

out=$(mc "$TMP/proj" profile bogus)
check "unknown subcommand shows usage" "unknown subcommand" "$out"

# --- degraded states --------------------------------------------------------
printf '\ndegraded states\n'
reset_state
mc "$TMP/proj" profile new work >/dev/null 2>&1
mc "$TMP/proj" profile use work >/dev/null 2>&1
rm -rf "$TMP/home/.multi-claude/profiles/work"
check_eq "removing a profile tree leaves the shared history" "yes" "$(test -d "$TMP/home/.claude/projects" && echo yes || echo GONE)"

out=$(mc "$TMP/proj" --version)
check "dangling mapping warns"                "no longer exists"     "$out"
check "dangling mapping falls back to default" "config_dir=[<UNSET>]" "$out"

out=$(mc "$TMP/proj" profile list)
check "list reports dangling, not active" "no longer exists" "$out"

# --- finding the real claude ------------------------------------------------
# The PATH walk once dropped the final entry, because `printf '%s'` left it
# without a trailing newline for `read`. Invisible in normal use.
printf '\nfinding the real claude\n'
reset_state
out=$(
    cd "$TMP/elsewhere" || exit 1
    unset CLAUDECODE CLAUDE_CONFIG_DIR CLAUDE_PROFILE
    HOME="$TMP/home"; PATH="/usr/bin:/bin:$TMP/stub"
    export HOME PATH
    "$SH" "$WRAPPER" --version 2>&1
)
check "stub in the LAST PATH entry is still found" "STUB" "$out"

out=$(
    cd "$TMP/elsewhere" || exit 1
    unset CLAUDECODE CLAUDE_CONFIG_DIR CLAUDE_PROFILE
    HOME="$TMP/home"; PATH="/usr/bin:/bin"
    export HOME PATH
    "$SH" "$WRAPPER" --version 2>&1
)
check "no claude on PATH reports clearly" "cannot find the real" "$out"

# A copy of the wrapper on PATH must be skipped, or the exec loops forever.
mkdir -p "$TMP/dup"
cp "$WRAPPER" "$TMP/dup/claude"
out=$(
    cd "$TMP/elsewhere" || exit 1
    unset CLAUDECODE CLAUDE_CONFIG_DIR CLAUDE_PROFILE
    HOME="$TMP/home"; PATH="$TMP/dup:$TMP/stub:/usr/bin:/bin"
    export HOME PATH
    "$SH" "$WRAPPER" --version 2>&1
)
check "a wrapper copy on PATH is skipped, no exec loop" "STUB" "$out"

# --- picker selection -------------------------------------------------------
printf '\npicker selection (tty gate neutralised)\n'
reset_state
mc "$TMP/proj" profile new work >/dev/null 2>&1

out=$(mc_pick "$TMP/proj" '1
' profile)
check "choosing 1 selects default" "-> default" "$out"

out=$(mc_pick "$TMP/proj" '2
' profile)
check "choosing 2 selects the profile" "-> work" "$out"

out=$(mc_pick "$TMP/proj" '99
' profile)
check "an out-of-range choice is rejected" "invalid choice" "$out"

out=$(mc_pick "$TMP/elsewhere" 'n
fresh
' profile)
check "'n' creates and selects a new profile" "-> fresh" "$out"
check_eq "the new profile exists" "yes" "$(test -d "$TMP/home/.multi-claude/profiles/fresh" && echo yes || echo no)"

# --- shared session history -------------------------------------------------
# projects/ and file-history/ inside a profile are symlinks into the fake ~/.claude.
printf '\nshared session history\n'
reset_state
mc "$TMP/proj" profile new work >/dev/null 2>&1
mc "$TMP/proj" profile use work >/dev/null 2>&1
W="$TMP/home/.multi-claude/profiles/work"
SHARED="$TMP/home/.claude"

check_eq "new links projects into ~/.claude"     "$SHARED/projects"     "$(readlink "$W/projects")"
check_eq "new links file-history into ~/.claude" "$SHARED/file-history" "$(readlink "$W/file-history")"

rm "$W/projects"
mc "$TMP/proj" --version >/dev/null 2>&1
check_eq "a missing link is recreated on launch" "$SHARED/projects" "$(readlink "$W/projects")"

# An empty real directory (Claude Code may create one) is swapped for the link.
rm "$W/projects"
mkdir "$W/projects"
mc "$TMP/proj" --version >/dev/null 2>&1
check_eq "an empty real dir is replaced by the link" "$SHARED/projects" "$(readlink "$W/projects")"

# A populated real directory is a pre-sharing profile: report it, touch nothing.
rm "$W/projects"
mkdir -p "$W/projects/slug"
: > "$W/projects/slug/old.jsonl"
out=$(mc "$TMP/proj" --version)
check "a populated real dir is reported"  "not shared yet" "$out"
check "and the launch still goes through" "STUB"           "$out"
check_eq "and its contents are untouched" "yes" "$(test -f "$W/projects/slug/old.jsonl" && test ! -L "$W/projects" && echo yes || echo no)"
rm -rf "$W/projects"

# Deleting a profile unlinks; it must never descend into the shared history.
mkdir -p "$SHARED/projects/x"
: > "$SHARED/projects/x/precious.jsonl"
out=$(mc_pick "$TMP/proj" 'y
' profile rm work)
check "rm deletes the profile" "deleted profile" "$out"
check_eq "shared transcripts survive rm" "yes" "$(test -f "$SHARED/projects/x/precious.jsonl" && echo yes || echo GONE)"

# default *is* ~/.claude and must never be linked to itself.
out=$(mc "$TMP/elsewhere" --version)
check_eq "default never links ~/.claude to itself" "yes" "$(test ! -L "$SHARED/projects" && echo yes || echo no)"

# --- directory listing ------------------------------------------------------
printf '\ndirectory listing\n'
reset_state
mc "$TMP/proj" profile new work >/dev/null 2>&1
mc "$TMP/proj" profile use work >/dev/null 2>&1
mc "$TMP/elsewhere" profile use default >/dev/null 2>&1
printf '/no/such/dir\twork\n' >> "$TMP/home/.multi-claude/dirmap"

out=$(mc "$TMP/proj" profile list)
check "list has a Directories block"   "Directories:"        "$out"
check "list shows a mapping"           "/proj -> work"       "$out"
check "list marks a missing directory" "(directory missing)" "$out"
first=$(printf '%s\n' "$out" | grep -F -- ' -> ' | head -n 1)
check "mappings come out sorted"       "/no/such/dir"        "$first"

rm -rf "$W"
out=$(mc "$TMP/proj" profile list)
check "list marks a missing profile"   "(profile missing)"   "$out"

# --- deleting default -------------------------------------------------------
printf '\ndeleting default\n'
reset_state
mc "$TMP/proj" profile use default >/dev/null 2>&1
MARKER="$TMP/home/.multi-claude/default-removed"

# `rm default` ran above with no other profile; the "only profile" check there
# proves the refusal. With a tty it must still refuse before touching anything.
out=$(mc_pick "$TMP/proj" 'y
' profile rm default)
check "alone, rm default errors even past the tty gate" "only profile" "$out"
check_eq "and writes no marker" "no" "$(test -f "$MARKER" && echo yes || echo no)"
check_absent "and never logs out" "auth logout" "$(cat "$TMP/calls.log" 2>/dev/null)"

mc "$TMP/proj" profile new work >/dev/null 2>&1
out=$(mc_pick "$TMP/proj" 'y
' profile rm default)
check "with another profile, rm default succeeds" "deleted profile 'default'" "$out"
check "and says ~/.claude is kept" "is kept" "$out"
check_eq "the marker exists" "yes" "$(test -f "$MARKER" && echo yes || echo no)"
check "logout ran with CLAUDE_CONFIG_DIR unset" "config_dir=[<UNSET>] args=[auth logout]" "$(cat "$TMP/calls.log")"
check_eq "its mapping is gone" "0" "$(dirmap_lines)"

out=$(mc "$TMP/proj" profile list)
check_absent "list no longer offers default" "  default" "$out"
out=$(mc_pick "$TMP/proj" '1
' profile)
check "the picker's first entry is now the other profile" "-> work" "$out"

out=$(
    cd "$TMP/elsewhere" || exit 1
    unset CLAUDECODE CLAUDE_CONFIG_DIR
    HOME="$TMP/home"; PATH="$TMP/stub:/usr/bin:/bin"; CLAUDE_PROFILE=default
    export HOME PATH CLAUDE_PROFILE
    "$SH" "$WRAPPER" --version 2>&1
)
check "CLAUDE_PROFILE=default is rejected" "does not exist" "$out"

out=$(mc "$TMP/elsewhere" --version </dev/null)
check "unmapped non-interactive run fails with the fix" "set CLAUDE_PROFILE" "$out"
check_absent "and does not reach claude" "STUB" "$out"

out=$(mc "$TMP/proj" profile new default)
check "new default names the way back" "default-removed" "$out"
out=$(mc "$TMP/elsewhere" profile list)
check "list says the picker will ask, not 'falls back'" "the picker will ask" "$out"
check_absent "and no longer claims a default fallback" "falls back to default" "$out"


# A directory profile's rm logs out of that directory, not of ~/.claude.
rm -f "$TMP/calls.log"
out=$(mc_pick "$TMP/proj" 'y
' profile rm work)
check "rm of a directory profile logs out of its dir" "profiles/work] args=[auth logout]" "$(cat "$TMP/calls.log")"
check_absent "with no default warning" "non-interactive runs" "$out"

# --- result -----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
