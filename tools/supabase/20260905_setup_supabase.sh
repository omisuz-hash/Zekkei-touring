#!/bin/bash
# Supabase の接続情報を対話で登録し、検証してから ~/.zekkei_supabase に保存する。
# 手順: 一時ファイルに書き出し → 検証 → 通過したら保存（既存があればバックアップ）。
set -euo pipefail
cd "$(dirname "$0")"
KEYFILE="$HOME/.zekkei_supabase"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

ask() {  # 空のまま Enter を押したら聞き直す
  local var="$1" desc="$2" val=""
  while [[ -z "${val}" ]]; do
    read -r -s -p "${desc}（入力は表示されません。貼り付けて Enter）: " val; echo
    [[ -z "${val}" ]] && echo "  空です。もう一度入力してください。"
  done
  printf 'export %s=%q\n' "${var}" "${val}" >> "$TMP"
}
echo "絶景道: Supabase 接続情報の登録"
url=""
while [[ -z "${url}" ]]; do
  read -r -p "Project URL（例 https://abcd1234.supabase.co。こちらは表示されます）: " url
  [[ -z "${url}" ]] && echo "  空です。もう一度入力してください。"
done
printf 'export SUPABASE_URL=%q\n' "${url}" >> "$TMP"
ask SUPABASE_PUBLISHABLE_KEY "Publishable key（sb_publishable_... または anon の eyJ...）"
ask SUPABASE_SECRET_KEY      "Secret key（sb_secret_... または service_role の eyJ...）"
ask SUPABASE_ACCESS_TOKEN    "Personal Access Token（sbp_...  https://supabase.com/dashboard/account/tokens で作成）"
chmod 600 "$TMP"

echo "検証中…"
if ( set -a; source "$TMP"; set +a; python3 20260905_db_admin.py check ); then
  [[ -f "$KEYFILE" ]] && cp -p "$KEYFILE" "$KEYFILE.bak.$(date +%Y%m%d%H%M%S)"
  mv "$TMP" "$KEYFILE"; trap - EXIT
  echo "保存しました: $KEYFILE"
  echo "以後は  source ~/.zekkei_supabase  で読み込めます。"
else
  echo "検証に失敗したため保存しませんでした。"; exit 1
fi
