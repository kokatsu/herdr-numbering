#!/bin/bash
# Prefix every tab name with its position ("[N] name" by default), and report
# every workspace's position as display-only metadata ("(N)" by default) for
# the sidebar's $number token. Both formats are configurable, see the config
# block below. Workspaces are never renamed: a rename would set the custom
# name and permanently stop herdr from deriving the label from the focused
# pane's cwd / Git repository root.
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
command -v "$herdr_bin" >/dev/null || {
  echo "renumber.sh: $herdr_bin not found (set HERDR_BIN_PATH)" >&2
  exit 1
}

# The number formats default to "[{n}]" for tabs and "({n})" for workspaces,
# so the two kinds stay distinguishable at a glance. Both can be overridden
# from config.toml in the directory herdr assigns the plugin
# (`herdr plugin config-dir kokatsu.tab-numbers`). Only the flat
# `key = "value"` form is recognized - pulling in a TOML parser for two keys
# is not worth a new dependency, though a trailing comment after the closing
# quote is tolerated - and a value without the {n} placeholder is ignored so a
# typo cannot erase every number
tab_format='[{n}]'
workspace_format='({n})'
config_file=${HERDR_PLUGIN_CONFIG_DIR:+$HERDR_PLUGIN_CONFIG_DIR/config.toml}
if [ -n "$config_file" ] && [ -f "$config_file" ]; then
  # Whitespace around a format is trimmed off: herdr trims reported token
  # values before storing them (verified on 0.8.2), so a padded workspace
  # format would never equal the stored token and the mismatch gates below
  # would re-report every workspace and pane on every event
  trim='s/^[[:space:]]*//;s/[[:space:]]*$//'
  v=$(sed -n 's/^[[:space:]]*tab_format[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$config_file" | tail -n 1 | sed "$trim")
  case $v in *"{n}"*) tab_format=$v ;; esac
  v=$(sed -n 's/^[[:space:]]*workspace_format[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$config_file" | tail -n 1 | sed "$trim")
  case $v in *"{n}"*) workspace_format=$v ;; esac
fi

# Turn a format template into the regex that recognizes labels it produced:
# regex-escape every text segment and put [0-9]+ in each {n} hole
format_to_regex() {
  local rest=$1 literal escaped
  while [[ $rest == *"{n}"* ]]; do
    literal=${rest%%"{n}"*}
    escaped=$(printf '%s' "$literal" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
    printf '%s[0-9]+' "$escaped"
    rest=${rest#*"{n}"}
  done
  escaped=$(printf '%s' "$rest" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  printf '%s' "$escaped"
}

# The strip pattern accepts the configured format plus the shipped default
# ([N]), so switching away from the default migrates existing labels instead
# of stacking a second prefix on top of the old one. No other alternates:
# anything else a label starts with is a real name, and stripping more than
# the formats this plugin actually writes would eat it
tab_strip="^($(format_to_regex "$tab_format")\\s*|\\[[0-9]+\\]\\s*)"

# Project one tab into {tab_id, label, want} and keep only the ones that need a
# rename. $tab and friends are jq variables, so keep the shell out of them
# shellcheck disable=SC2016
numbering='
  [.result.tabs | group_by(.workspace_id)[] | to_entries[] | .value + {pos: (.key + 1)}][]
  | . as $tab
  | ($fmt | gsub("\\{n\\}"; ($tab.pos | tostring))) as $prefix
  | ($tab.label | sub($strip; "")) as $stripped
  | {
      tab_id: $tab.tab_id,
      label: $tab.label,
      want: (if ($stripped | test("^[0-9]*$")) then $prefix else "\($prefix) \($stripped)" end)
    }
  | select(.want != .label)
'

# The workspace pass rides on herdr's own numbering: unlike the stable tab
# number, `workspace list`'s `number` field reflows to stay equal to the
# sidebar position (verified on 0.8.2 by closing a middle workspace), so it is
# used directly instead of recomputing positions. No strip is involved because
# labels are never touched: the number only exists as metadata
# shellcheck disable=SC2016
# Pairs of "workspace_id token" split on the first space, like pane_tokens:
# workspace ids cannot contain spaces, tokens can. Only mismatches are
# emitted: the snapshot already carries the visible tokens, so the steady
# state costs zero commands, like the tab pass's `.want != .label` gate
ws_token='
  .result.workspaces[]
  | . as $ws
  | ($fmt | gsub("\\{n\\}"; ($ws.number | tostring))) as $want
  | select(($ws.tokens.number? // "") != $want)
  | "\($ws.workspace_id) \($want)"
'

# Panes carry their workspace's number too, because the agents section of the
# sidebar resolves custom tokens from pane metadata, not workspace metadata.
# The output pairs "pane_id token" split on the first space; pane ids cannot
# contain spaces, tokens can
# shellcheck disable=SC2016
pane_tokens='
  ($ws.result.workspaces | map({key: .workspace_id, value: .number}) | from_entries) as $num
  | .result.panes[]
  | . as $pane
  # Indexing with null throws in jq, so a pane record without a workspace_id
  # (none seen live, but not guaranteed during teardown) must not kill the
  # whole pass
  | select($pane.workspace_id != null)
  | $num[$pane.workspace_id] as $n
  | select($n != null)
  | ($fmt | gsub("\\{n\\}"; ($n | tostring))) as $want
  | select(($pane.tokens.wsnum? // "") != $want)
  | "\($pane.pane_id) \($want)"
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
  tab_ids=$(printf '%s' "$tabs_json" | jq -r --arg fmt "$tab_format" --arg strip "$tab_strip" "$numbering | .tab_id" 9>&-) || return 1
  # A here-string feeds an empty variable as one empty line, which would reach
  # tab rename as an empty id
  [ -n "$tab_ids" ] || return 0

  # Take labels one at a time from the raw output of jq -r, with no delimiter in
  # between. @tsv turns a backslash into \\ and read -r does not decode it, so a
  # tab named "foo\bar" would gain a backslash on every rename and never converge
  while IFS= read -r tab_id; do
    label=$(printf '%s' "$tabs_json" | jq -r --arg fmt "$tab_format" --arg strip "$tab_strip" --arg id "$tab_id" "$numbering | select(.tab_id == \$id) | .want" 9>&-) || return 1
    # The list is a snapshot, so a tab can be gone by the time its turn comes -
    # closing a pane is one of the events this plugin subscribes to. Letting
    # that fail the run would leave every later tab on its old number
    "$herdr_bin" tab rename "$tab_id" "$label" 9>&- >/dev/null || true
  done <<<"$tab_ids"
}

# The workspace pass reports each workspace's number as display-only metadata
# for the sidebar's $number token, instead of renaming. Reports do not emit
# an event this plugin subscribes to, and the metadata does not survive a
# server restart (the startup hook re-reports it)
number_workspaces() {
  local ws_json=$1 pairs ws_id token
  pairs=$(printf '%s' "$ws_json" | jq -r --arg fmt "$workspace_format" "$ws_token" 9>&-) || return 1
  [ -n "$pairs" ] || return 0

  # read's IFS split only touches the edges of the token, and the format trim
  # above keeps those free of whitespace; interior spaces (a format like
  # "No. {n}") land in $token verbatim
  while read -r ws_id token; do
    # The workspace can be gone by the time its turn comes - workspace.closed
    # is one of the triggers - so a failed report is tolerated
    "$herdr_bin" workspace report-metadata "$ws_id" --source kokatsu.tab-numbers --token number="$token" 9>&- >/dev/null || true
  done <<<"$pairs"
}

# Mirror each workspace's number onto its panes as a wsnum token, for the
# agents section of the sidebar
number_panes() {
  local ws_json=$1 panes_json pairs pane_id token
  panes_json=$("$herdr_bin" pane list 9>&-) || return 1

  pairs=$(printf '%s' "$panes_json" | jq -r --arg fmt "$workspace_format" \
    --argjson ws "$ws_json" "$pane_tokens" 9>&-) || return 1
  [ -n "$pairs" ] || return 0

  while read -r pane_id token; do
    # The pane can be gone by the time its turn comes - pane.closed is one of
    # the triggers - so a failed report is tolerated
    "$herdr_bin" pane report-metadata "$pane_id" --source kokatsu.tab-numbers --token wsnum="$token" 9>&- >/dev/null || true
  done <<<"$pairs"
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
  # One snapshot serves both passes: it halves the plugin-command IPC per
  # event and keeps the two passes from disagreeing about the numbers
  if ws_json=$("$herdr_bin" workspace list 9>&-); then
    number_workspaces "$ws_json" || {
      echo "renumber.sh: workspace pass failed" >&2
      pass_failed=1
    }
    number_panes "$ws_json" || {
      echo "renumber.sh: pane pass failed" >&2
      pass_failed=1
    }
  else
    echo "renumber.sh: workspace list failed" >&2
    pass_failed=1
  fi
  # Check for pending work only after dropping the lock. Checking while still
  # holding it and then leaving lets a process that arrives between the check
  # and the EXIT trap drop a marker that nobody picks up
  release
  [ -e "$pending" ] || break
  # Failing to reacquire is fine: whoever took it will handle the fresh list
  acquire || break
done

[ -z "$pass_failed" ] || exit 1
