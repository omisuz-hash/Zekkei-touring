#!/bin/bash
# Xcode プロジェクトの生成とコンパイル確認（Mac 用）
#   ./20260905_setup_xcode.sh            生成 → シミュレータ向けにコンパイル → Xcode で開く
#   ./20260905_setup_xcode.sh --no-open  Xcode を開かない（コンパイル結果だけ見る）
#   ./20260905_setup_xcode.sh --no-apple-signin   無料の Apple ID で署名エラーが出るときに、Apple でサインインの機能を外して生成
#   ./20260905_setup_xcode.sh --run      Xcode の画面操作なしで、シミュレータを起動してアプリを入れて開く（署名不要）
#   ./20260905_setup_xcode.sh --archive  配布用に書き出す（TestFlight へ送る .ipa を作る）。Team ID が必要
#   ./20260905_setup_xcode.sh --team XXXXXXXXXX   Team ID を登録して保存する（初回のみ。以後は省略可）
#   ./20260905_setup_xcode.sh --run --sim "iPhone 17 Pro Max"   端末を指定して起動する（App Store 用の画面写真を撮るとき）
# 前提: Xcode（App Store）、Homebrew。xcodegen は無ければこのスクリプトが入れる。
# 接続先は ~/.zekkei_supabase から読み、Local.xcconfig（git 管理外）に書き出す。
set -uo pipefail

# 配布する版は project.yml の MARKETING_VERSION が持ち主。
# スクリプト側に既定値を書くと、書き忘れたときに古い版で配布してしまう
project_version() {
  awk -F'"' '/^ *MARKETING_VERSION:/{print $2; exit}' "$(dirname "$0")/project.yml"
}

# シミュレータの画面を開く。
# Xcode 27 で Simulator.app は廃止され、DeviceHub.app が置き換わった。
# 古い Xcode も残っている環境があるため、新しい順に試す。
open_sim_window() {
  local hub="$(xcode-select -p)/../Applications/DeviceHub.app"
  if [[ -d "$hub" ]] && open -a "$hub" 2>/dev/null; then return 0; fi
  open -b com.apple.DeviceHub 2>/dev/null && return 0
  open -b com.apple.iphonesimulator 2>/dev/null && return 0
  open -a Simulator 2>/dev/null && return 0
  local simapp="$(xcode-select -p)/Applications/Simulator.app"
  [[ -d "$simapp" ]] && open -a "$simapp" 2>/dev/null && return 0
  cat <<'EOS'
シミュレータの画面を開けませんでした。アプリ自体はシミュレータ内で動いています。
  画面を画像で取り出す: xcrun simctl io booted screenshot ~/Desktop/sim.png
  Xcode から開く:       Xcode → Window → Devices and Simulators
EOS
  return 0
}

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"
OPEN=1; APPLE=1; RUN=0; ARCHIVE=0; SIMNAME=""
TEAMFILE="$HOME/.zekkei_ios"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open) OPEN=0 ;;
    --no-apple-signin) APPLE=0 ;;
    --run) RUN=1; OPEN=0 ;;
    --sim) SIMNAME="${2:-}"; shift ;;
    --archive) ARCHIVE=1; OPEN=0 ;;
    --team) shift; printf 'ZEKKEI_TEAM_ID=%s\n' "${1:-}" > "$TEAMFILE"; chmod 600 "$TEAMFILE"; echo "Team ID を保存しました: $TEAMFILE" ;;
  esac
  shift
done
TEAM_ID=""
if [[ -f "$TEAMFILE" ]]; then
  TEAM_ID="$(sed -n 's/^ZEKKEI_TEAM_ID=//p' "$TEAMFILE" | tr -d '\r\n')"
fi

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
ZEKKEI_TEAM_ID = ${TEAM_ID}
XC
[[ -n "$TEAM_ID" ]] && echo "Team ID: ${TEAM_ID}" || echo "Team ID: 未登録（実機・配布のビルドには --team で登録が必要）"

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

if [[ $ARCHIVE -eq 1 ]]; then
  echo "== 5/5 配布用の書き出し =="
  if [[ -z "$TEAM_ID" ]]; then
    echo "Team ID が未登録です。次を一度だけ実行してください:  ./20260905_setup_xcode.sh --team あなたのTeamID"; exit 1
  fi
  mkdir -p build
  cat > build/ExportOptions.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PL
  # ビルド番号は毎回更新する（同じ番号は App Store Connect が受け付けないため）
  BUILD_NO="$(date +%Y%m%d%H%M)"
  VERSION="${ZEKKEI_VERSION:-$(project_version)}"
  echo "版: $VERSION"
  echo "ビルド番号: $BUILD_NO"
  rm -rf build/ZekkeiTouring.xcarchive build/export
  xcodebuild -project ZekkeiTouring.xcodeproj -scheme ZekkeiTouring -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/ZekkeiTouring.xcarchive \
    CURRENT_PROJECT_VERSION="$BUILD_NO" MARKETING_VERSION="$VERSION" \
    -allowProvisioningUpdates archive 2>&1 | tee build/last_archive.log | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" | sort -u
  if ! grep -q "ARCHIVE SUCCEEDED" build/last_archive.log; then
    if grep -q "no devices" build/last_archive.log; then
      echo
      echo "ヒント: Apple の仕様で、書き出しには実機の登録が 1 台必要です。"
      echo "  iPhone を Mac に USB で繋ぎ、iPhone 側で「このコンピュータを信頼」を選んでから、もう一度実行してください。"
      echo "  繋ぐだけで端末が自動登録されます（TestFlight の受け取りには使いません）。"
    fi
    echo "== 書き出しに失敗しました。上の error: 行を Claude に貼ってください（全文は build/last_archive.log） =="; exit 1
  fi
  xcodebuild -exportArchive -archivePath build/ZekkeiTouring.xcarchive \
    -exportOptionsPlist build/ExportOptions.plist -exportPath build/export \
    -allowProvisioningUpdates 2>&1 | tee build/last_export.log | grep -E "error:|EXPORT SUCCEEDED" | sort -u
  IPA="$(find build/export -name '*.ipa' 2>/dev/null | head -1)"
  if [[ -z "$IPA" ]]; then
    if grep -q "PLA Update available" build/last_export.log; then
      echo
      echo "ヒント: Apple の利用許諾契約（Program License Agreement）の更新が未承諾です。"
      echo "  承諾するまで Apple 側が配布用証明書の発行を止めるため、「iOS Distribution が見つからない」も"
      echo "  併せて出ます。アーカイブ自体は成功しているので、承諾後にもう一度実行すれば通ります。"
      echo
      echo "  1) https://developer.apple.com/account を開く（Account Holder のアカウントで）"
      echo "  2) 画面上部の契約更新の案内から、更新された契約に同意する"
      echo "  3) 数分おいて、もう一度  ./20260905_setup_xcode.sh --archive"
    elif grep -q 'No signing certificate' build/last_export.log; then
      echo
      echo "ヒント: 配布用の証明書が Mac にありません。Xcode の Settings → Accounts で Apple ID を追加し、"
      echo "  チームを選んで Manage Certificates から Apple Distribution を作成してから、もう一度実行してください。"
    fi
    echo "== .ipa が作られませんでした。build/last_export.log を確認してください =="; exit 1
  fi
  echo "== 完成: $(pwd)/$IPA =="
  echo
  echo "TestFlight へ送るには、次のどちらかを行ってください。"
  echo "  A) Xcode の Organizer から:  open build/ZekkeiTouring.xcarchive"
  echo "  B) コマンドで送る（App Store Connect の App 用パスワードが必要）:"
  echo "     xcrun altool --upload-app -f \"$IPA\" -t ios -u あなたのAppleID -p アプリ用パスワード"
  exit 0
fi

if [[ $RUN -eq 1 ]]; then
  echo "== 5/5 シミュレータで起動 =="
  # 使う端末は一度決めたら固定する（毎回変わるとホーム画面からアイコンが消えるため）。
  # 別の端末に変えたい場合は  rm ~/.zekkei_sim  してから実行する。
  SIMFILE="$HOME/.zekkei_sim"
  DEVICE=""
  # --sim で端末を名前で選ぶ（画面写真の大きさを App Store の規定に合わせたいとき）
  if [[ -n "$SIMNAME" ]]; then
    DEVICE="$(xcrun simctl list devices available | grep -F "$SIMNAME (" | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
    if [[ -z "$DEVICE" ]]; then
      echo "「$SIMNAME」のシミュレータがありません。使えるものは次の通りです:"
      xcrun simctl list devices available | grep -E '^\s+iPhone' | sed -E 's/^\s+/  /; s/ \(.*//' | sort -u
      echo "無い場合は Xcode → Settings → Components から追加してください。"
      exit 1
    fi
    printf '%s' "$DEVICE" > "$SIMFILE"
  fi
  if [[ -z "$DEVICE" && -f "$SIMFILE" ]]; then
    CAND="$(cat "$SIMFILE")"
    xcrun simctl list devices available | grep -q "$CAND" && DEVICE="$CAND"
  fi
  if [[ -z "$DEVICE" ]]; then
    DEVICE="$(xcrun simctl list devices available | grep -E '^\s+iPhone' | grep -vE 'SE|mini' | tail -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
    [[ -n "$DEVICE" ]] && printf '%s' "$DEVICE" > "$SIMFILE"
  fi
  if [[ -z "$DEVICE" ]]; then
    echo "iPhone のシミュレータが見つかりません。Xcode → Settings → Components で iOS シミュレータを追加してください。"; exit 1
  fi
  NAME="$(xcrun simctl list devices available | grep "$DEVICE" | sed -E 's/^\s+//; s/ \(.*//')"
  echo "端末: $NAME"
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  open_sim_window
  xcodebuild -project ZekkeiTouring.xcodeproj -scheme ZekkeiTouring -destination "id=$DEVICE" -configuration Debug \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" MARKETING_VERSION="$(project_version)" \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/last_run_build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
  APP="$(find build/DerivedData -name 'ZekkeiTouring.app' -path '*iphonesimulator*' | head -1)"
  if [[ -z "$APP" ]]; then echo "アプリの生成物が見つかりません（build/last_run_build.log を確認）"; exit 1; fi
  xcrun simctl install "$DEVICE" "$APP" && xcrun simctl launch "$DEVICE" com.zekkeido.app >/dev/null && echo "起動しました。Simulator の画面を見てください。"
  echo "疑似的に走行させる:  xcrun simctl location $DEVICE start --speed=15 36.109,138.157 36.149,138.147 36.223,138.138"
  echo "位置を固定する:      xcrun simctl location $DEVICE set 36.109,138.157"
  echo "次回アプリだけ開く:  ~/zekkei-open   （ビルドせずにホーム画面のアイコンから開くのと同じ）"
  # ビルド無しで開き直すための短い起動コマンドを置く
  cat > "$HOME/zekkei-open" <<EOS
#!/bin/bash
# 絶景道をシミュレータで開く（ビルドはしない）。最新版にするときは 20260905_setup_xcode.sh --run
D="\$(cat "$SIMFILE")"
xcrun simctl boot "\$D" 2>/dev/null || true
# Xcode 27 以降は Simulator.app が廃止され、DeviceHub.app が画面を受け持つ
open -a "\$(xcode-select -p)/../Applications/DeviceHub.app" 2>/dev/null \
  || open -b com.apple.iphonesimulator 2>/dev/null \
  || open -a Simulator 2>/dev/null || true
sleep 2
xcrun simctl launch "\$D" com.zekkeido.app >/dev/null && echo "起動しました"
EOS
  chmod +x "$HOME/zekkei-open"
else
  echo "== 5/5 Xcode で開く =="
  [[ $OPEN -eq 1 ]] && open ZekkeiTouring.xcodeproj
  echo "Xcode 上部中央の実行先を iPhone のシミュレータにして ▶ を押すとアプリが起動します。"
fi
