# 絶景道の公開ページ

アプリから参照する対外ページの元データ。tidalworks.jp に設置する。

| ファイル | 設置先の URL | 用途 |
|---|---|---|
| `index.html` | `https://tidalworks.jp/zekkeido/` | アプリの紹介。App Store Connect のサポート URL / マーケティング URL |
| `terms.html` | `https://tidalworks.jp/zekkeido/terms` | ログイン画面の「利用規約」 |
| `privacy.html` | `https://tidalworks.jp/zekkeido/privacy` | ログイン画面の「プライバシーポリシー」、App Store Connect の必須項目 |

参照先は `ios/ZekkeiTouring/Models/AppLinks.swift` に集約している。URL を変える場合はそちらも直す。

## 設置のしかた

tidalworks.jp は WordPress で動いているため、WordPress の書き換え規則より先に
実体のファイルが返るよう、**フォルダを作って `index.html` として置く**。

```
public_html/
  zekkeido/
    index.html            → https://tidalworks.jp/zekkeido/
    terms/index.html      → https://tidalworks.jp/zekkeido/terms
    privacy/index.html    → https://tidalworks.jp/zekkeido/privacy
```

WordPress の `.htaccess` は「実体のファイルまたはフォルダが無いとき」だけ
`index.php` に流す作りになっている。実体のフォルダを置けばそちらが優先されるため、
WordPress 側の設定変更は要らない。

ファイル名は設置先の URL になるため、日付を頭に付けていない。

## 内容を直すとき

アプリの実際の挙動に合わせて書いてある。次を変えたときは、文面も合わせて見直すこと。

- 位置情報の扱い（軌跡を端末内に留める方針、プライバシーゾーン）
- 閲覧枠の付与数、失効の条件、枠の対象になる範囲
- 外部サービスの構成（Supabase、ログイン提供元、地図、YouTube）
- アカウント削除で消えるもの／残るもの

## ページ内のリンクについて

各ページはフォルダの下に `index.html` として置かれるため、URL は
`/zekkeido/terms/` のように末尾がスラッシュになる。この状態で `./privacy` と
書くと `/zekkeido/terms/privacy` に解決されてしまうため、**ページ間のリンクは
`/zekkeido/privacy/` のような絶対パスで書く**こと。
