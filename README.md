# herdr-tab-numbers

A [herdr](https://github.com/herdrdev/herdr) plugin that prefixes every tab name
with its position on the tab bar, and every workspace name with its position in
the sidebar, so you can see which `switch_tab` key (`prefix+1`..`prefix+9`) or
`switch_workspace` key jumps where. Tabs and workspaces use different shapes so
the two kinds of number stay distinguishable at a glance.

```text
tab bar:  [1] server   [2] logs   [3] nvim
sidebar:  (1) work     (2) dotfiles
```

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
0.8.2), so the plugin displays it directly, as `(2) dotfiles`. A purely
numeric workspace name is kept, because workspace auto-names come from the
directory name and `3` can be a real directory.

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
replaced, and a value without it is ignored. Keep some separator around `{n}`:
a bare `"{n}"` format makes the strip pattern match any leading digits, so a
name like `2026 planning` would lose its year. Only the flat `key = "value"` form
is parsed. Labels written in the configured format, or in any format this plugin
ships as a default, are
recognized and rewritten when the format changes; switching between two custom
formats can leave the old prefix behind, in which case renaming the affected
tab or workspace once clears it.

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

Tab numbering needs no configuration or key binding; jumping to a workspace by
its number needs `switch_workspace` bound (unset by default, see above).
Numbering is applied on startup and whenever the set of tabs or workspaces
changes.

## How it works

`renumber.sh` rewrites every tab name in every workspace, and every workspace
name, to its numbered form. It runs on `startup` (to recover after a server restart or
live handoff), on `tab.created`, `tab.closed`, `tab.moved`, `tab.renamed`,
`pane.closed`, and `pane.exited`, and on `workspace.created`,
`workspace.closed`, `workspace.moved`, `workspace.reordered`, and
`workspace.renamed`.

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
