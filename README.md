# herdr-tab-numbers

A [herdr](https://github.com/herdrdev/herdr) plugin that prefixes every tab name
with its position on the tab bar, so you can see which `switch_tab` key
(`prefix+1`..`prefix+9`) jumps to which tab.

```text
[1] server   [2] logs   [3] nvim
```

## Why position, not tab number

herdr assigns each tab a stable number that survives closing and reordering, so
it develops gaps and stops matching what `switch_tab` does. `switch_tab`
resolves by position on the tab bar, and that is what this plugin displays.

Tabs you never named carry an auto-generated name that is the position itself
(`"3"`), so a purely numeric name is treated as "no name" and rendered as `[3]`
alone rather than `[3] 3`.

## Requirements

- herdr 0.7.5 or newer (developed and tested against 0.8.0)
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

No configuration or key binding is needed. Numbering is applied on startup and
whenever the set of tabs changes.

## How it works

`renumber.sh` rewrites every tab name in every workspace to `[N] name`. It runs
on `startup` (to recover after a server restart or live handoff) and on
`tab.created`, `tab.closed`, `tab.moved`, `tab.renamed`, `pane.closed`, and
`pane.exited`.

`pane.closed` and `pane.exited` are included because closing the last pane of a
tab does not always emit `tab.closed`. `tab.renamed` is included so a manual
rename gets its `[N]` back; the plugin's own rename re-fires that event, but the
second pass finds no difference and issues no rename, so it converges.

The lock and the pending marker live in the directory herdr hands the plugin
through `HERDR_PLUGIN_STATE_DIR`, keyed by the full socket path so that separate
herdr sessions never share them.

Renaming a tab to the name it already has still emits `tab.renamed`, so a large
tab set can fan out into more concurrent plugin commands than herdr allows
(the limit is 32; a 16-tab renumber was observed to hit it). To avoid that, the
real work is funnelled through a single process: a run that cannot take the lock
drops a pending marker and exits immediately, and the lock holder makes another
pass over a fresh tab list.

## License

MIT. See [LICENSE](LICENSE).
