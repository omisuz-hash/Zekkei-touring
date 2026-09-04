#!/bin/bash
# 集中実行: API の枠が許す限り、処理対象が無くなるまで回し続ける（1 回の実行の上限を引き上げる）。
# 通常の毎日実行（20260904_run_daily.sh）と同じ SQLite を使うので、途中で止めても翌朝の自動実行が続きを引き継ぐ。
#   ./20260904_run_burst.sh            前面で実行（ターミナルを閉じると止まる）
#   ./20260904_run_burst.sh --bg       裏で実行（ターミナルを閉じても続く。ログは out/logs/）
set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$(dirname "$0")"
if [[ "${1:-}" == "--bg" ]]; then
  nohup "$0" > /dev/null 2>&1 &
  echo "裏で開始しました。進み具合: tail -f $(pwd)/out/logs/burst_*.log"; exit 0
fi
source "$HOME/.zekkei_keys"
export SEED_MAX_VIDEOS=1500 SEED_MAX_VIDEO_ANALYSES=60 SEED_MAX_GEO=800 SEED_CHANNELS_PER_RUN=30 SEED_YT_BUDGET=9800
mkdir -p out/logs
LOG="out/logs/burst_$(date +%Y%m%d_%H%M).log"
REPO="$(git rev-parse --show-toplevel)"
{
  echo "== $(date '+%Y-%m-%d %H:%M') 集中実行 開始 =="
  (cd "$REPO" && git pull --no-rebase --no-edit --quiet) || (cd "$REPO" && git merge --abort 2>/dev/null; echo "git pull に失敗。既存のコードで続行")
  python3 20260904_seed_pipeline.py run --until-empty
  cd "$REPO"
  git add -f tools/seedpipeline/out/*.md tools/seedpipeline/out/*.geojson tools/seedpipeline/out/*.sql 2>/dev/null
  git diff --cached --quiet || (git commit -q -m "シード集中収集 $(date '+%Y-%m-%d %H:%M')" && (git pull --no-rebase --no-edit -q || git merge --abort); git push -q && echo "結果を push しました")
  echo "== $(date '+%Y-%m-%d %H:%M') 集中実行 終了 =="
} 2>&1 | tee -a "$LOG"
