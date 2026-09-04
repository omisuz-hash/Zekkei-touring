#!/bin/bash
# Mac の launchd に毎日 03:00 の自動実行を登録する（Mac が起動していれば実行される）。
#   ./20260904_install_daily.sh          登録
#   ./20260904_install_daily.sh --now    登録して、すぐ 1 回実行
#   ./20260904_install_daily.sh --remove 解除
set -euo pipefail
cd "$(dirname "$0")"
LABEL="com.zekkei.seedpipeline"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$(pwd)/20260904_run_daily.sh"
mkdir -p "$HOME/Library/LaunchAgents" out/logs

if [[ "${1:-}" == "--remove" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "解除しました。"; exit 0
fi

[[ -f "$HOME/.zekkei_keys" ]] || { echo "先に ./20260904_setup_keys.sh でキーを登録してください。"; exit 1; }

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
  <key>WorkingDirectory</key><string>$(pwd)</string>
  <key>StandardOutPath</key><string>$(pwd)/out/logs/launchd.out</string>
  <key>StandardErrorPath</key><string>$(pwd)/out/logs/launchd.err</string>
  <key>RunAtLoad</key><false/>
</dict></plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
echo "登録しました: 毎日 03:00 に $SCRIPT を実行します。"
echo "状態確認:  launchctl list | grep $LABEL"
echo "ログ:      ls $(pwd)/out/logs/"

if [[ "${1:-}" == "--now" ]]; then
  echo "今すぐ 1 回実行します（ログは out/logs/ に出ます。終了まで数十分かかります）"
  launchctl kickstart "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl start "$LABEL"
fi
