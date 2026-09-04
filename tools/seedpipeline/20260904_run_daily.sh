#!/bin/bash
# 毎日 1 回、YouTube の無料枠いっぱいまで収集して結果を書き出す。
# 使い方: 1) 下の 3 つのキーを ~/.zekkei_keys に書く（chmod 600）  2) このスクリプトを launchd か cron で毎日実行
#   ~/.zekkei_keys の中身:
#     export YOUTUBE_API_KEY=...
#     export GEMINI_API_KEY=...
#     export GOOGLE_MAPS_API_KEY=...
set -euo pipefail
cd "$(dirname "$0")"
source "$HOME/.zekkei_keys"
mkdir -p out/logs
python3 20260904_seed_pipeline.py run 2>&1 | tee "out/logs/$(date +%Y%m%d_%H%M).log"
