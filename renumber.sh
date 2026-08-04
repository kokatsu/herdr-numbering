#!/bin/bash
# 全ワークスペースのタブ名を "[N] 名前" 形式に揃える。
#
# N は herdr の安定番号 (tab list の number) ではなくタブバー上の位置。
# switch_tab (prefix+1..9) が位置で解決することを 0.7.5 の実機で確認済みで、
# 安定番号は欠番が出るため一致しない。
#
# 名前を持たないタブの自動生成名は位置番号そのもの ("3" 等) なので、
# 数字だけの名前は名前なしとみなし "[3]" だけにする。
set -euo pipefail

herdr_bin=${HERDR_BIN_PATH:-herdr}
# セッションごとにタブ集合が別なので、ソケットの置き場でキーを分ける
runtime_dir=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
session_key=$(basename "$(dirname "${HERDR_SOCKET_PATH:-herdr/default.sock}")")
lock_file="$runtime_dir/herdr-tab-numbers.$session_key.lock"
pending="$runtime_dir/herdr-tab-numbers.$session_key.pending"

# 取得失敗を「他プロセスが保持中」と区別できないと採番が黙って止まるため、
# perl 不在はフックログに残して落とす
command -v perl >/dev/null || {
  echo "renumber.sh: perl が必要です (flock に使用)" >&2
  exit 1
}

# タブ 1 件を {tab_id, label, want} に射影し、リネームが要るものだけ残す。
# $tab などは jq の変数なのでシェル展開させない
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

renumber() {
  local tabs_json tab_id label
  tabs_json=$("$herdr_bin" tab list)

  # ラベルは区切り文字を挟まず jq -r の生出力で 1 件ずつ受け取る。
  # @tsv はバックスラッシュを \\ に変換し read -r が復号しないため、
  # "foo\bar" のようなタブ名でリネームのたびに \ が倍増して収束しなくなる
  while IFS= read -r tab_id; do
    label=$(printf '%s' "$tabs_json" | jq -r --arg id "$tab_id" "$numbering | select(.tab_id == \$id) | .want")
    "$herdr_bin" tab rename "$tab_id" "$label" >/dev/null
  done < <(printf '%s' "$tabs_json" | jq -r "$numbering | .tab_id")
}

# rename は同じラベルへの rename でも tab.renamed を再発火するため、タブ数が
# 多いと連鎖が一気に膨らむ。16 タブを一斉に採番した実測では同時 32 プロセスの
# 上限に達し 35 件が "maximum concurrent plugin commands reached (32)" で失敗した。
#
# そこで実処理は常に 1 プロセスに畳む。待ち行列を作ると待機中のプロセスも
# 上限に数えられてしまうので、ロックを取れなかった側は保留マークだけ置いて即降り、
# 保持者が最新の一覧でもう一周する
lock_held=""

# ロックは OS の advisory lock (flock(2))。ファイルやディレクトリの有無で
# 代用すると、異常終了で残った分を回収する仕組みが要り、その回収自体が
# 二重所有の競合を生む (シェルに CAS がないため条件付きの奪取が書けない)。
# flock なら SIGKILL やクラッシュでもカーネルが確実に解放する。
# flock(1) は util-linux 由来で macOS に無いため perl 経由で掛ける。
# ロックは fd 9 の open file description に紐づくので、perl の終了後も
# このスクリプトが fd を保持する限り維持される
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

# bash はシグナルハンドラを実行したあと本体を続行するため、シグナルでは必ず
# exit する。解放は EXIT に一本化し、自分が保持していないロックは触らない
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

acquire || {
  : >"$pending"
  exit 0
}

while :; do
  rm -f "$pending"
  renumber
  # 保留の判定はロックを手放してから行う。保持したまま判定して抜けると、
  # 判定後 EXIT trap までの間に来たプロセスが保留を置いて降り、誰も拾わない
  release
  [ -e "$pending" ] || break
  # 取れなければ取得できた側が最新の一覧で処理するので、ここで降りてよい
  acquire || break
done
