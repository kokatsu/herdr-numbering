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

# A failure to acquire the lock cannot be told apart from "another process holds
# it", so a missing dependency would stop the numbering silently. Both are
# checked up front and treated as fatal, which puts the reason in the hook log.
# The assignment below does propagate a jq failure on its own, but the up-front
# check names the missing dependency instead of leaving a bare jq error
command -v perl >/dev/null || {
  echo "renumber.sh: perl is required (used for flock and Digest::SHA)" >&2
  exit 1
}
perl -MDigest::SHA -e 1 2>/dev/null || {
  echo "renumber.sh: perl module Digest::SHA is required" >&2
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

# Hash the full socket path so separators and literal underscores cannot
# collapse different sessions onto the same lock. Use Perl's Digest::SHA to
# avoid requiring a separate hash executable.
session_key=$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])' "${HERDR_SOCKET_PATH:-default}")
lock_file="$runtime_dir/herdr-numbering.$session_key.lock"
pending="$runtime_dir/herdr-numbering.$session_key.pending"

# Turn a format template into the regex that recognizes labels it produced:
# regex-escape every text segment and put [0-9]+ in each {n} hole
format_to_regex() {
  local rest=$1 literal escaped
  while [[ $rest == *"{n}"* ]]; do
    literal=${rest%%"{n}"*}
    escaped=$(printf '%s' "$literal" | sed 's/[][\\.^$*+?(){}|]/\\&/g') || return 1
    printf '%s[0-9]+' "$escaped"
    rest=${rest#*"{n}"}
  done
  escaped=$(printf '%s' "$rest" | sed 's/[][\\.^$*+?(){}|]/\\&/g') || return 1
  printf '%s' "$escaped"
}

# The number formats default to "[{n}]" for tabs and "({n})" for workspaces,
# so the two kinds stay distinguishable at a glance. Both can be overridden
# from config.toml in the directory herdr assigns the plugin
# (`herdr plugin config-dir kokatsu.numbering`). Only the flat
# `key = "value"` form is recognized - pulling in a TOML parser for two keys
# is not worth a new dependency, though a trailing comment after the closing
# quote is tolerated - and a value without the {n} placeholder is ignored so a
# typo cannot erase every number
#
# Every step returns its failure explicitly: load_config runs as the left side
# of ||, where set -e is suspended for the whole function body
load_config() {
  local trim v
  tab_format='[{n}]'
  workspace_format='({n})'
  config_file=${HERDR_PLUGIN_CONFIG_DIR:+$HERDR_PLUGIN_CONFIG_DIR/config.toml}
  if [ -n "$config_file" ] && [ -f "$config_file" ]; then
    # Whitespace around a format is trimmed off: herdr trims reported token
    # values before storing them (verified on 0.8.2), so a padded workspace
    # format would never equal the stored token and the mismatch gates below
    # would re-report every workspace and pane on every event
    trim='s/^[[:space:]]*//;s/[[:space:]]*$//'
    v=$(sed -n 's/^[[:space:]]*tab_format[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$config_file" | tail -n 1 | sed "$trim") || return 1
    case $v in *"{n}"*) tab_format=$v ;; esac
    v=$(sed -n 's/^[[:space:]]*workspace_format[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$config_file" | tail -n 1 | sed "$trim") || return 1
    case $v in *"{n}"*) workspace_format=$v ;; esac
  fi

  # The strip pattern accepts the configured format plus the shipped default
  # ([N]), so switching away from the default migrates existing labels instead
  # of stacking a second prefix on top of the old one. No other alternates:
  # anything else a label starts with is a real name, and stripping more than
  # the formats this plugin actually writes would eat it
  tab_strip="^($(format_to_regex "$tab_format")\\s*|\\[[0-9]+\\]\\s*)" || return 1
}

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
  ($ws.result.workspaces | map(select(.number != null) | .number as $n | {
    key: .workspace_id,
    value: ($fmt | gsub("\\{n\\}"; ($n | tostring)))
  }) | from_entries) as $tokens
  | .result.panes[]
  | . as $pane
  # Indexing with null throws in jq, so a pane record without a workspace_id
  # (none seen live, but not guaranteed during teardown) must not kill the
  # whole pass
  | select($pane.workspace_id != null)
  | $tokens[$pane.workspace_id] as $want
  | select($want != null)
  | select(($pane.tokens.wsnum? // "") != $want)
  | "\($pane.pane_id) \($want)"
'

# A failed update is harmless only if its target disappeared from a fresh
# list. Other failures must reach the hook log without skipping later targets.
update_existing() {
  local kind=$1 id=$2 operation=$3 snapshot
  shift 3
  "$herdr_bin" "$kind" "$operation" "$id" "$@" 9>&- </dev/null >/dev/null && return 0
  snapshot=$("$herdr_bin" "$kind" list 9>&- </dev/null) || return 1
  printf '%s' "$snapshot" | jq -e --arg collection "${kind}s" --arg field "${kind}_id" --arg id "$id" \
    '.result[$collection] | all(.[$field] != $id)' 9>&- >/dev/null
}

# Every fallible command here returns explicitly instead of leaning on errexit:
# the caller invokes this on the left of ||, and that disables errexit for the
# whole body, so a failed assignment would otherwise fall through to the empty
# check and report success
renumber() {
  local tabs_json pairs tab_id encoded_label label failed=0
  tabs_json=$("$herdr_bin" tab list 9>&-) || return 1

  # Capture the whole result before updating: a jq error after partial output
  # must fail the pass instead of applying an incomplete set of labels.
  # An empty id would shift the label into the id field once read collapses the
  # leading tab, and a NUL cannot survive a shell variable or a CLI argument
  pairs=$(printf '%s' "$tabs_json" | jq -r --arg fmt "$tab_format" --arg strip "$tab_strip" "$numbering
    | if (.tab_id | type != \"string\" or . == \"\") then error(\"tab id must be a non-empty string\")
      elif (.want | explode | any(. == 0)) then error(\"tab label contains NUL: \(.tab_id)\")
      else [.tab_id, .want] | @tsv end" 9>&-) || return 1
  # A here-string feeds an empty variable as one empty line, which would reach
  # tab rename as an empty id
  [ -n "$pairs" ] || return 0

  # @tsv escapes tabs, newlines, carriage returns and backslashes. Decode with
  # printf -v so command substitution cannot strip trailing label newlines.
  while IFS=$'\t' read -r tab_id encoded_label; do
    printf -v label '%b' "$encoded_label"
    update_existing tab "$tab_id" rename "$label" || failed=1
  done <<<"$pairs"
  return "$failed"
}

# The workspace pass reports each workspace's number as display-only metadata
# for the sidebar's $number token, instead of renaming. Reports do not emit
# an event this plugin subscribes to, and the metadata does not survive a
# server restart (the startup hook re-reports it)
number_workspaces() {
  local ws_json=$1 pairs ws_id token failed=0
  pairs=$(printf '%s' "$ws_json" | jq -r --arg fmt "$workspace_format" "$ws_token" 9>&-) || return 1
  [ -n "$pairs" ] || return 0

  # read's IFS split only touches the edges of the token, and load_config's
  # format trim keeps those free of whitespace; interior spaces (a format like
  # "No. {n}") land in $token verbatim
  while read -r ws_id token; do
    update_existing workspace "$ws_id" report-metadata --source kokatsu.numbering --token number="$token" || failed=1
  done <<<"$pairs"
  return "$failed"
}

# Mirror each workspace's number onto its panes as a wsnum token, for the
# agents section of the sidebar
number_panes() {
  local ws_json=$1 panes_json pairs pane_id token failed=0
  panes_json=$("$herdr_bin" pane list 9>&-) || return 1

  pairs=$(printf '%s' "$panes_json" | jq -r --arg fmt "$workspace_format" \
    --argjson ws "$ws_json" "$pane_tokens" 9>&-) || return 1
  [ -n "$pairs" ] || return 0

  while read -r pane_id token; do
    update_existing pane "$pane_id" report-metadata --source kokatsu.numbering --token wsnum="$token" || failed=1
  done <<<"$pairs"
  return "$failed"
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
config_failed=""
load_config || {
  echo "renumber.sh: config load failed" >&2
  pass_failed=1
  config_failed=1
}

while :; do
  rm -f "$pending"
  # A pass can fail on its own (herdr unreachable, malformed JSON). Dying here
  # would strand the marker with no process left to act on it, so record it and
  # carry on to the check below, then exit non-zero once the loop is done so the
  # plugin log does not record the run as a success
  # Without the configured formats, numbering with the defaults would relabel
  # everything, so skip the passes but still reach the pending check below
  if [ -z "$config_failed" ]; then
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
