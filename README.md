# herdr-tab-numbers

A [herdr](https://github.com/herdrdev/herdr) plugin that prefixes every tab name
with its position on the tab bar, and shows every workspace's position in the
sidebar, so you can see which `switch_tab` key (`prefix+1`..`prefix+9`) or
`switch_workspace` key jumps where. Tabs and workspaces use different shapes so
the two kinds of number stay distinguishable at a glance.

```text
tab bar:  [1] server   [2] logs   [3] nvim
sidebar:  (1) work     (2) dotfiles
```

Workspace numbers are display-only metadata, not part of the name: the label
itself is never renamed, so herdr keeps deriving it from the focused pane's
working directory / Git repository root the way it does out of the box.
Showing them requires one line of sidebar configuration — see Install.

`switch_workspace` is unset by default; bind it (for example to
`prefix+shift+1..9`) in `config.toml` to jump by the displayed number.

## Why position, not tab number

herdr assigns each tab a stable number that survives closing and reordering, so
it develops gaps and stops matching what `switch_tab` does. `switch_tab`
resolves by position on the tab bar, and that is what this plugin displays.

Tabs you never named carry an auto-generated name that is the position itself
(`"3"`), so a purely numeric name is treated as "no name" and rendered as `[3]`
alone rather than `[3] 3`.

Workspaces are simpler: herdr keeps the `number` of `workspace list` equal to
the sidebar position (closing a workspace renumbers the rest, verified on
0.8.2), so the plugin reports it directly.

Workspaces are also why the number is metadata rather than a rename: renaming
a workspace sets its custom name, and herdr then permanently stops deriving
the label from the focused pane's cwd / Git repository root — nothing clears a
custom name once set. Reporting the number through
`workspace report-metadata` leaves the label untouched.

Upgrading from 0.2.0, which renamed workspaces to `(1) work`, needs one manual
step: rename each workspace once to drop the burned-in prefix, or it doubles
up with the metadata token. The plugin does not do this by itself — it cannot
tell a 0.2.0 leftover from a real name someone chose, and renaming the wrong
one would freeze that workspace's label for good. Note that a workspace 0.2.0
renamed is already frozen on its custom name; the cwd-following behavior
described above only survives on workspaces that were never renamed.

## Configuration

The formats default to `[{n}]` for tabs and `({n})` for workspaces. To change
either, create `config.toml` in the directory this prints:

```bash
herdr plugin config-dir kokatsu.tab-numbers
```

```toml
tab_format = "[{n}]"
workspace_format = "({n})"
```

`{n}` marks where the number goes and must be present; every occurrence is
replaced, and a value without it is ignored. Only the flat `key = "value"` form
is parsed. Whitespace around a value is trimmed off — herdr trims reported
token values before storing them, so padding could never show up in the
sidebar anyway. For tabs, keep some separator around `{n}`: a bare `"{n}"` format
makes the strip pattern match any leading digits of real tab names. Tab labels
written in the configured format, or in the default `[{n}]`, are recognized
and rewritten when the format changes; switching between two custom formats
can leave the old prefix behind, in which case renaming the affected tab once
clears it. `workspace_format` only shapes the metadata token, so it can be
changed freely.

## Requirements

- herdr 0.8.2 or newer — the workspace pass relies on `workspace list`
  renumbering `number` to match the sidebar position, and the config file is
  found through `HERDR_PLUGIN_CONFIG_DIR`; both were verified on 0.8.2
- `bash`
- `jq`
- `perl` — used for `flock(2)`, because `flock(1)` from util-linux is not
  available on macOS

## Install

```bash
herdr plugin install kokatsu/herdr-tab-numbers
```

Or, to run from a local checkout:

```bash
git clone https://github.com/kokatsu/herdr-tab-numbers
herdr plugin link ./herdr-tab-numbers
```

Tab numbering needs no configuration. Workspace numbers are exposed as
custom sidebar tokens, which the default sidebar does not render — `$number`
on each workspace, and `$wsnum` on each pane for the agents section. Add them
to the sidebar rows in herdr's `config.toml` as desired:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "$number", "workspace"], ["branch", "git_status"]]

[ui.sidebar.agents.rows_by_agent]
claude = [
  ["state_icon", "$wsnum", "workspace", "tab"],
  ["terminal_title_stripped"],
  ["agent"],
]
```

(Both are herdr's default layouts with the token inserted — put `"$wsnum"`
wherever it reads best.) Jumping
to a workspace by its number needs `switch_workspace` bound (unset by
default, see above). Numbering is applied on startup and whenever the set of
tabs, workspaces, or panes changes.

## How it works

`renumber.sh` rewrites every tab name in every workspace to its numbered
form, and reports every workspace's number as display-only metadata (source
`kokatsu.tab-numbers`): token `number` on the workspace, and token `wsnum` on
each of its panes, because the agents section of the sidebar resolves custom
tokens from pane metadata. It runs on `startup` (to recover after a server
restart or live handoff — reported metadata does not survive one), on
`tab.created`, `tab.closed`, `tab.moved`, `tab.renamed`, `pane.created`,
`pane.moved`, `pane.closed`, and `pane.exited`, and on `workspace.created`,
`workspace.closed`, `workspace.moved`, and `workspace.reordered`.
`workspace.renamed` is not watched: a rename cannot disturb metadata, and
numbers only move when the set or order of workspaces changes.

`pane.closed` and `pane.exited` are included because closing the last pane of a
tab does not emit `tab.closed`. `tab.renamed` is included so a manual
rename gets its `[N]` back; the plugin's own rename re-fires that event, but the
second pass finds no difference and issues no rename, so it converges.

The lock and the pending marker live in `XDG_RUNTIME_DIR`, falling back to the
directory herdr hands the plugin through `HERDR_PLUGIN_STATE_DIR`. Both are
private to the user, and the first is cleared on reboot. They are keyed by the
full socket path, so separate herdr sessions never share them.

Renaming a tab to the name it already has still emits `tab.renamed`, so a large
tab set can fan out into more concurrent plugin commands than herdr allows
(the limit is 32; a 16-tab renumber was observed to hit it). To avoid that, the
real work is funnelled through a single process: a run that cannot take the lock
drops a pending marker and exits immediately, and the lock holder makes another
pass over a fresh tab list.

## License

MIT. See [LICENSE](LICENSE).
