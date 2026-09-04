#!/bin/bash
# API キーを対話で入力し、~/.zekkei_keys に保存して検証する。
# 手順: バックアップ → 一時ファイルに書き出し → 検証 → 通過したら置換。失敗時は元に戻す。
set -euo pipefail
cd "$(dirname "$0")"
KEYFILE="$HOME/.zekkei_keys"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

ask() {  # ask 変数名 説明
  local var="$1" desc="$2" val
  read -r -s -p "$desc（入力は表示されません。空なら省略）: " val; echo
  printf 'export %s=%q\n' "$var" "$val" >> "$TMP"
}

echo "絶景道 シード収集ツール: API キーの登録"
ask YOUTUBE_API_KEY      "YouTube Data API v3 のキー"
ask GEMINI_API_KEY       "Gemini API のキー"
read -r -p "Google Maps は 1 つのキーで Geocoding と Routes 両方を許可していますか？ [y/n]: " one
if [[ "$one" =~ ^[Yy] ]]; then
  ask GOOGLE_MAPS_API_KEY "Google Maps のキー（Geocoding + Routes）"
else
  ask GOOGLE_GEOCODING_API_KEY "Geocoding API のキー"
  ask GOOGLE_ROUTES_API_KEY    "Routes API のキー"
fi
printf 'export GEO_PROVIDER=google\n' >> "$TMP"

# 空の値は書かない
grep -v "=''$" "$TMP" > "$TMP.clean" && mv "$TMP.clean" "$TMP"
chmod 600 "$TMP"

if [[ -f "$KEYFILE" ]]; then
  cp -p "$KEYFILE" "$KEYFILE.bak.$(date +%Y%m%d%H%M%S)"
  echo "既存の設定をバックアップしました。"
fi

echo "検証中…"
# 一時ファイルの内容で検証。通過したら本番ファイルに置き換える
if ( set -a; source "$TMP"; set +a; python3 20260904_seed_pipeline.py check ); then
  mv "$TMP" "$KEYFILE"
  trap - EXIT
  echo "保存しました: $KEYFILE"
  echo "以後は  source ~/.zekkei_keys  で読み込めます。"
else
  echo "検証に失敗したため保存しませんでした（既存の設定は変更していません）。"
  echo "Google Cloud で該当 API の有効化とキーの制限を確認して、再実行してください。"
  exit 1
fi
