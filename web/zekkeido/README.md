# 絶景道の公開ページ

アプリから参照する対外ページの元データ。tidalworks.jp に設置する。

| ファイル | 設置先の URL | アプリからの参照元 |
|---|---|---|
| `terms.html` | `https://tidalworks.jp/zekkeido/terms` | ログイン画面の「利用規約」 |
| `privacy.html` | `https://tidalworks.jp/zekkeido/privacy` | ログイン画面の「プライバシーポリシー」、App Store Connect の必須項目 |

参照先は `ios/ZekkeiTouring/Models/AppLinks.swift` に集約している。URL を変える場合はそちらも直す。

## 設置のしかた

拡張子なしの URL（`/zekkeido/terms`）で開けるようにする。サーバーの作りに応じて次のいずれか。

- `zekkeido/terms/index.html` として置く
- `zekkeido/terms.html` として置き、拡張子なしでも引けるよう設定する

ファイル名は設置先の URL になるため、日付を頭に付けていない。

## 内容を直すとき

アプリの実際の挙動に合わせて書いてある。次を変えたときは、文面も合わせて見直すこと。

- 位置情報の扱い（軌跡を端末内に留める方針、プライバシーゾーン）
- 閲覧枠の付与数、失効の条件、枠の対象になる範囲
- 外部サービスの構成（Supabase、ログイン提供元、地図、YouTube）
- アカウント削除で消えるもの／残るもの
