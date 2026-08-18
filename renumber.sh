#!/bin/bash
# Normalize every tab name in every workspace to "[N] name".
#
# N is the tab's position on the tab bar, not herdr's stable tab number (the
# `number` field of `tab list`). switch_tab (prefix+1..9) was confirmed on
# herdr 0.7.5 to resolve by position, and the stable number develops gaps, so
# the two stop matching.
#
# A tab that was never named carries an auto-generated name that is the
# position itself ("3"), so a purely numeric name is treated as no name and
# rendered as "[3]" alone.
set -euo pipefail

herdr_bin=${HERDR_BIN_PATH:-herdr}
# herdr creates a private state directory per plugin and names it in the
# environment of every runtime command, so require it rather than reconstructing
# herdr's layout here. min_herdr_version gates the versions that provide it
state_dir=${HERDR_PLUGIN_STATE_DIR:?renumber.sh: HERDR_PLUGIN_STATE_DIR is not set (run this through herdr)}
# The lock and the marker are runtime state, so prefer the runtime directory:
# it is per-user (0700) and is cleared on reboot, which keeps one file per
# session from accumulating. The state directory is the fallback because a
# world-writable /tmp is not a safe place for a predictable file name
runtime_dir=${XDG_RUNTIME_DIR:-$state_dir}
mkdir -p "$runtime_dir"

# Each session has its own set of tabs, so key the state on the socket path.
# The whole path is sanitized rather than reduced to its parent directory name:
# the default session lives at ~/.config/herdr/herdr.sock and a named one at
# ~/.config/herdr/sessions/<name>/herdr.sock, so the parent directory alone
# collides between the default session and a session named "herdr", which is a
# name herdr accepts. Hashing would be an option but sha256sum is not part of a
# stock macOS
session_key=$(printf '%s' "${HERDR_SOCKET_PATH:-default}" | tr -c '[:alnum:]._-' '_')
lock_file="$runtime_dir/herdr-tab-numbers.$session_key.lock"
pending="$runtime_dir/herdr-tab-numbers.$session_key.pending"

# A failure to acquire the lock cannot be told apart from "another process holds
# it", so a missing dependency would stop the numbering silently. Both are
# checked up front and treated as fatal, which puts the reason in the hook log.
# The assignment below does propagate a jq failure on its own, but the up-front
# check names the missing dependency instead of leaving a bare jq error
command -v perl >/dev/null || {
  echo "renumber.sh: perl is required (used for flock)" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "renumber.sh: jq is required" >&2
  exit 1
}

# Project one tab into {tab_id, label, want} and keep only the ones that need a
# rename. $tab and friends are jq variables, so keep the shell out of them
# shellcheck disable=SC2016
numbering='
  [.result.tabs | group_by(.workspace_id)[] | to_entries[] | .value + {pos: (.key + 1)}][]
  | . as $tab
  | ($tab.label | sub("^\\[[0-9]+\\]\\s*"; "")) as $stripped
  | {
      tab_id: $tab.tab_id,
      label: $tab.label,
      want: (if ($stripped | test("^[0-9]*$")) then "[\($tab.pos)]" else "[\($tab.pos)] \($stripped)" end)
    }
  | select(.want != .label)
'

# Every fallible command here returns explicitly instead of leaning on errexit:
# the caller invokes this on the left of ||, and that disables errexit for the
# whole body, so a failed assignment would otherwise fall through to the empty
# check and report success
renumber() {
  local tabs_json tab_ids tab_id label
  tabs_json=$("$herdr_bin" tab list 9>&-) || return 1

  # Collect the ids through an assignment rather than a process substitution, so
  # that a jq failure is caught instead of quietly numbering nothing
  tab_ids=$(printf '%s' "$tabs_json" | jq -r "$numbering | .tab_id" 9>&-) || return 1
  # A here-string feeds an empty variable as one empty line, which would reach
  # tab rename as an empty id
  [ -n "$tab_ids" ] || return 0

  # Take labels one at a time from the raw output of jq -r, with no delimiter in
  # between. @tsv turns a backslash into \\ and read -r does not decode it, so a
  # tab named "foo\bar" would gain a backslash on every rename and never converge
  while IFS= read -r tab_id; do
    label=$(printf '%s' "$tabs_json" | jq -r --arg id "$tab_id" "$numbering | select(.tab_id == \$id) | .want" 9>&-) || return 1
    # The list is a snapshot, so a tab can be gone by the time its turn comes -
    # closing a pane is one of the events this plugin subscribes to. Letting
    # that fail the run would leave every later tab on its old number
    "$herdr_bin" tab rename "$tab_id" "$label" 9>&- >/dev/null || true
  done <<<"$tab_ids"
}

# A rename re-fires tab.renamed even when the label is unchanged, so with many
# tabs the chain grows fast. Renumbering 16 tabs at once was measured to reach
# the limit of 32 concurrent commands, with 35 of them failing on
# "maximum concurrent plugin commands reached (32)".
#
# So the real work is always funnelled through a single process. Queueing would
# not help, because a waiting process still counts toward the limit: a run that
# cannot take the lock only drops a pending marker and exits, and the holder
# makes another pass over a fresh list
lock_held=""

# The lock is an OS advisory lock (flock(2)). Standing in for it with the
# presence of a file or directory would need a way to reclaim whatever a crash
# left behind, and that reclaim is itself a race for double ownership (the shell
# has no CAS, so a conditional steal cannot be written). With flock the kernel
# releases it reliably, even on SIGKILL or a crash.
# flock(1) comes from util-linux and is absent on macOS, so perl takes the lock.
# The lock belongs to the open file description behind fd 9, so it outlives the
# perl process as long as this script keeps the fd open
exec 9>"$lock_file"

acquire() {
  perl -e 'use Fcntl qw(:flock); open(my $fh, ">&=9") or exit 1; flock($fh, LOCK_EX | LOCK_NB) or exit 1;' || return 1
  lock_held=1
  return 0
}

release() {
  [ -n "$lock_held" ] || return 0
  lock_held=""
  perl -e 'use Fcntl qw(:flock); open(my $fh, ">&=9") or exit 1; flock($fh, LOCK_UN) or exit 1;' || true
}

# bash resumes the main body after running a signal handler, so a handler must
# always exit. Releasing happens only on EXIT, and never for a lock this process
# does not hold
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Mark before acquiring, not after failing to acquire. The other order leaves a
# window in which the holder releases and checks the marker before the loser has
# written it, and the event that woke the loser is then never numbered
: >"$pending"

acquire || exit 0

pass_failed=""

while :; do
  rm -f "$pending"
  # A pass can fail on its own (herdr unreachable, malformed JSON). Dying here
  # would strand the marker with no process left to act on it, so record it and
  # carry on to the check below, then exit non-zero once the loop is done so the
  # plugin log does not record the run as a success
  renumber || {
    echo "renumber.sh: renumber pass failed" >&2
    pass_failed=1
  }
  # Check for pending work only after dropping the lock. Checking while still
  # holding it and then leaving lets a process that arrives between the check
  # and the EXIT trap drop a marker that nobody picks up
  release
  [ -e "$pending" ] || break
  # Failing to reacquire is fine: whoever took it will handle the fresh list
  acquire || break
done

[ -z "$pass_failed" ] || exit 1
