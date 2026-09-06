#!/bin/bash
# Xcode プロジェクトの生成とコンパイル確認（Mac 用）
#   ./20260905_setup_xcode.sh            生成 → シミュレータ向けにコンパイル → Xcode で開く
#   ./20260905_setup_xcode.sh --no-open  Xcode を開かない（コンパイル結果だけ見る）
#   ./20260905_setup_xcode.sh --no-apple-signin   無料の Apple ID で署名エラーが出るときに、Apple でサインインの機能を外して生成
#   ./20260905_setup_xcode.sh --run      Xcode の画面操作なしで、シミュレータを起動してアプリを入れて開く（署名不要）
# 前提: Xcode（App Store）、Homebrew。xcodegen は無ければこのスクリプトが入れる。
# 接続先は ~/.zekkei_supabase から読み、Local.xcconfig（git 管理外）に書き出す。
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"
OPEN=1; APPLE=1; RUN=0
for a in "$@"; do
  [[ "$a" == "--no-open" ]] && OPEN=0
  [[ "$a" == "--no-apple-signin" ]] && APPLE=0
  [[ "$a" == "--run" ]] && { RUN=1; OPEN=0; }
done

echo "== 1/5 ツールの確認 =="
if ! xcode-select -p >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode が見つかりません。App Store から Xcode をインストールし、一度起動して追加コンポーネントを入れてから再実行してください。"
  echo "インストール後にこのエラーが続く場合:  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
xcodebuild -version | head -1
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew が見つかりません。次の 1 行をターミナルに貼って導入してから再実行してください。"
  echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen を導入します（初回のみ、数分）"
  brew install xcodegen || { echo "xcodegen の導入に失敗しました"; exit 1; }
fi

echo "== 2/5 接続先の埋め込み =="
SUPABASE_URL=""; SUPABASE_PUBLISHABLE_KEY=""
if [[ -f "$HOME/.zekkei_supabase" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/.zekkei_supabase"
  echo "Supabase: ${SUPABASE_URL}"
else
  echo "~/.zekkei_supabase が無いため、テスト用データ（モック）で動く設定にします。"
fi
GOOGLE_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}"
REVERSED="com.zekkeido.placeholder"
if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
  # 123-abc.apps.googleusercontent.com → com.googleusercontent.apps.123-abc
  REVERSED="com.googleusercontent.apps.${GOOGLE_CLIENT_ID%%.apps.googleusercontent.com}"
fi
# xcconfig では // がコメント扱いになるため、URL は https:/$()/ と書く
SAFE_URL="${SUPABASE_URL/https:\/\//https:/\$()/}"
cat > Local.xcconfig <<XC
// 20260905_setup_xcode.sh が生成。手で編集しない。git 管理外
SUPABASE_URL = ${SAFE_URL}
SUPABASE_ANON_KEY = ${SUPABASE_PUBLISHABLE_KEY}
GOOGLE_CLIENT_ID = ${GOOGLE_CLIENT_ID}
GOOGLE_REVERSED_CLIENT_ID = ${REVERSED}
XC

echo "== 3/5 プロジェクト生成 =="
SPEC=project.yml
if [[ $APPLE -eq 0 ]]; then
  python3 - <<'PY'
import re
s=open('project.yml').read()
s=re.sub(r"    entitlements:\n(?:      .*\n)+", "", s)
open('project.generated.yml','w').write(s)
PY
  SPEC=project.generated.yml
  echo "（Apple でサインインの機能を外して生成します）"
fi
xcodegen generate --spec "$SPEC" --quiet || { echo "プロジェクト生成に失敗しました"; exit 1; }
echo "生成: ZekkeiTouring.xcodeproj"

echo "== 4/5 シミュレータ向けにコンパイル（初回は依存パッケージの取得で数分） =="
mkdir -p build
xcodebuild -project ZekkeiTouring.xcodeproj -scheme ZekkeiTouring \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/last_build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" | sed 's#'"$(pwd)"'/##' | sort -u
if grep -q "BUILD SUCCEEDED" build/last_build.log; then
  echo "== コンパイル成功 =="
else
  echo "== コンパイル失敗: 上の error: 行を Claude に貼ってください（全文は build/last_build.log） =="
fi

if [[ $RUN -eq 1 ]]; then
  echo "== 5/5 シミュレータで起動 =="
  DEVICE="$(xcrun simctl list devices available | grep -E '^\s+iPhone' | grep -vE 'SE|mini' | tail -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
  if [[ -z "$DEVICE" ]]; then
    echo "iPhone のシミュレータが見つかりません。Xcode → Settings → Components で iOS シミュレータを追加してください。"; exit 1
  fi
  NAME="$(xcrun simctl list devices available | grep "$DEVICE" | sed -E 's/^\s+//; s/ \(.*//')"
  echo "端末: $NAME"
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  open -a Simulator
  xcodebuild -project ZekkeiTouring.xcodeproj -scheme ZekkeiTouring -destination "id=$DEVICE" -configuration Debug \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/last_run_build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
  APP="$(find build/DerivedData -name 'ZekkeiTouring.app' -path '*iphonesimulator*' | head -1)"
  if [[ -z "$APP" ]]; then echo "アプリの生成物が見つかりません（build/last_run_build.log を確認）"; exit 1; fi
  xcrun simctl install "$DEVICE" "$APP" && xcrun simctl launch "$DEVICE" com.zekkeido.app >/dev/null && echo "起動しました。Simulator の画面を見てください。"
  echo "疑似的に走行させる:  xcrun simctl location $DEVICE start --speed=15 36.109,138.157 36.149,138.147 36.223,138.138"
  echo "位置を固定する:      xcrun simctl location $DEVICE set 36.109,138.157"
else
  echo "== 5/5 Xcode で開く =="
  [[ $OPEN -eq 1 ]] && open ZekkeiTouring.xcodeproj
  echo "Xcode 上部中央の実行先を iPhone のシミュレータにして ▶ を押すとアプリが起動します。"
fi
