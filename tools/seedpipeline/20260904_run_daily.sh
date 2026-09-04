#!/bin/bash
# 毎日 1 回、YouTube の無料枠いっぱいまで収集して結果を書き出し、結果を git に push する。
# launchd（20260904_install_daily.sh で登録）から呼ばれる前提。手動実行も可。
# キーは ~/.zekkei_keys に置く（20260904_setup_keys.sh で作成）。
set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="ja_JP.UTF-8"
cd "$(dirname "$0")"
REPO="$(git rev-parse --show-toplevel)"
mkdir -p out/logs
LOG="out/logs/$(date +%Y%m%d_%H%M).log"
exec > >(tee -a "$LOG") 2>&1

echo "== $(date '+%Y-%m-%d %H:%M') 開始 =="
if [[ ! -f "$HOME/.zekkei_keys" ]]; then
  echo "キーファイル ~/.zekkei_keys がありません。20260904_setup_keys.sh を実行してください。"; exit 1
fi
# shellcheck disable=SC1090
source "$HOME/.zekkei_keys"

# 1. コードの更新を取り込む（Claude 側の改善を自動で反映）
(cd "$REPO" && git pull --ff-only --quiet) || echo "git pull に失敗しました（手元の変更と衝突）。既存のコードで続行します。"

# 2. 収集
python3 20260904_seed_pipeline.py run
STATUS=$?

# 3. 結果を push（レポート・GeoJSON・SQL のみ。SQLite とログは push しない）
cd "$REPO"
git add -f tools/seedpipeline/out/*.md tools/seedpipeline/out/*.geojson tools/seedpipeline/out/*.sql 2>/dev/null
if ! git diff --cached --quiet; then
  git commit -q -m "シード自動収集 $(date +%Y-%m-%d)" && git push -q && echo "結果を push しました"
else
  echo "結果に変更はありません"
fi
echo "== $(date '+%Y-%m-%d %H:%M') 終了 (exit $STATUS) =="
exit $STATUS
