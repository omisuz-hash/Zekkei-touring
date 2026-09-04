#!/usr/bin/env python3
"""YouTube Data API v3 で動画の概要欄・チャプター・コメントを取得し、道名の候補を抽出する。

使い方（Mac のターミナル）:
    cd <このリポジトリ>/tools/youtube
    YOUTUBE_API_KEY=xxxx python3 20260904_fetch_youtube_meta.py
    # 追加の動画があれば URL を引数で渡す
    YOUTUBE_API_KEY=xxxx python3 20260904_fetch_youtube_meta.py https://www.youtube.com/watch?v=XXXX

出力:
    out/<日付>_youtube_videos.json  取得した生データ
    out/<日付>_youtube_videos.md    人が読む用のまとめ（Claude に渡す）

追加インストールは不要（Python 標準ライブラリのみ）。API キーはコードに書かず環境変数から読む。
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date

API = "https://www.googleapis.com/youtube/v3"

# Omi 提供の 17 本
DEFAULT_VIDEO_IDS = [
    "0QZ8HaXH3TE", "55mZGv5rVUA", "16-vGPSHZ1s", "OylkgI2aLt8", "emCNMVAazPM",
    "yk35t9WzC4I", "-lzOAlQn_0s", "1EjOocqM2n8", "ogmS4WnhKa0", "hFnxjLmo4Lo",
    "kw4Mnu9HmgU", "0VSlkuGJz8k", "cwJTfPdLDj8", "icqXcnXub-s", "LoGcVMQ07h0",
    "Hn_kvbBy7Rg", "S3g-AdZtH7g",
]

# 道名らしい語の抽出パターン（概要欄・コメントから候補を拾う。最終判断は人が行う）
# 道名は漢字・カタカナ・英数字が中心のため、助詞（は・を・で 等）を巻き込まないよう平仮名は前置部分に含めない
_K = r"[一-龥ァ-ヶA-Za-z0-9ー]"
ROAD_PATTERNS = [
    _K + r"{1,15}(?:ライン|スカイライン|パークウェイ|ロード|街道|林道|有料道路|道路|バイパス)",
    r"(?:国道|県道|都道|府道|道道|市道|農道|広域農道)\s?\d{1,4}\s?号(?:線)?",
    _K + r"{1,10}(?:峠|トンネル|ループ橋|大橋|ダム|高原|湿原|湖|岬|渓谷|展望台|展望所)",
    r"道の駅\s?" + _K + r"{1,10}",
    _K + r"{1,10}(?:みち)",
]
STOPWORDS = {"バイク道路", "高速道路", "一般道路", "道路", "この道路", "山道路"}


def api_key() -> str:
    key = os.environ.get("YOUTUBE_API_KEY", "").strip()
    if not key:
        sys.exit("環境変数 YOUTUBE_API_KEY が設定されていません。\n例: YOUTUBE_API_KEY=xxxx python3 20260904_fetch_youtube_meta.py")
    return key


def get(path: str, params: dict) -> dict:
    params = {**params, "key": api_key()}
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "ignore")
        try:
            reason = json.loads(body)["error"]["errors"][0].get("reason", "")
        except Exception:
            reason = ""
        if reason == "commentsDisabled":
            return {"items": [], "_disabled": True}
        if e.code == 403 and "quota" in body.lower():
            sys.exit("本日の API 利用枠を使い切りました。明日再実行してください。")
        if e.code in (400, 403):
            sys.exit(f"API エラー {e.code}: キーが無効か、YouTube Data API v3 が有効化されていない可能性があります。\n{body[:300]}")
        raise


def extract_video_id(s: str) -> str | None:
    s = s.strip()
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", s):
        return s
    m = re.search(r"(?:v=|youtu\.be/|shorts/|embed/)([A-Za-z0-9_-]{11})", s)
    return m.group(1) if m else None


def parse_duration(iso: str) -> int:
    m = re.fullmatch(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", iso or "")
    if not m:
        return 0
    h, mi, s = (int(x or 0) for x in m.groups())
    return h * 3600 + mi * 60 + s


def parse_chapters(description: str) -> list[dict]:
    """概要欄の「0:00 タイトル」形式の行をチャプターとして抽出"""
    out = []
    for line in description.splitlines():
        m = re.match(r"\s*\(?(\d{1,2}:\d{2}(?::\d{2})?)\)?\s*[\-–—:：]?\s*(.+)", line)
        if m:
            out.append({"time": m.group(1), "title": m.group(2).strip()})
    return out


def road_candidates(text: str) -> list[str]:
    found = []
    for pat in ROAD_PATTERNS:
        for m in re.finditer(pat, text):
            w = m.group(0).strip()
            if w and w not in STOPWORDS and w not in found and len(w) >= 3:
                found.append(w)
    return found


def fetch_videos(ids: list[str]) -> list[dict]:
    videos = []
    for i in range(0, len(ids), 50):
        chunk = ids[i:i + 50]
        data = get("videos", {"part": "snippet,contentDetails,statistics", "id": ",".join(chunk)})
        for it in data.get("items", []):
            sn, cd, st = it["snippet"], it.get("contentDetails", {}), it.get("statistics", {})
            videos.append({
                "id": it["id"],
                "url": f"https://www.youtube.com/watch?v={it['id']}",
                "title": sn.get("title", ""),
                "channel": sn.get("channelTitle", ""),
                "channel_id": sn.get("channelId", ""),
                "published_at": sn.get("publishedAt", ""),
                "duration_s": parse_duration(cd.get("duration", "")),
                "view_count": int(st.get("viewCount", 0) or 0),
                "like_count": int(st.get("likeCount", 0) or 0),
                "comment_count": int(st.get("commentCount", 0) or 0),
                "tags": sn.get("tags", []),
                "description": sn.get("description", ""),
                "thumbnail": (sn.get("thumbnails", {}).get("maxres") or sn.get("thumbnails", {}).get("high") or {}).get("url", ""),
            })
    return videos


def fetch_comments(video_id: str, limit: int = 100) -> tuple[list[dict], bool]:
    comments, token, disabled = [], None, False
    while len(comments) < limit:
        params = {"part": "snippet,replies", "videoId": video_id, "maxResults": 100,
                  "order": "relevance", "textFormat": "plainText"}
        if token:
            params["pageToken"] = token
        data = get("commentThreads", params)
        if data.get("_disabled"):
            disabled = True
            break
        for th in data.get("items", []):
            top = th["snippet"]["topLevelComment"]["snippet"]
            entry = {"author": top.get("authorDisplayName", ""), "text": top.get("textDisplay", ""),
                     "likes": top.get("likeCount", 0), "replies": []}
            for rep in th.get("replies", {}).get("comments", []):
                rs = rep["snippet"]
                entry["replies"].append({"author": rs.get("authorDisplayName", ""), "text": rs.get("textDisplay", "")})
            comments.append(entry)
        token = data.get("nextPageToken")
        if not token:
            break
    return comments[:limit], disabled


def fmt_duration(s: int) -> str:
    return f"{s // 60}:{s % 60:02d}"


def write_markdown(videos: list[dict], path: str) -> None:
    lines = [f"# YouTube 動画メタデータ取得結果（{date.today().isoformat()}）", "",
             f"取得本数: {len(videos)}。概要欄・チャプター・コメントから道名候補を機械抽出したもの。最終判断は人が行う。", ""]
    for v in videos:
        lines += [f"## {v['title']}", "",
                  f"- URL: {v['url']}",
                  f"- チャンネル: {v['channel']}",
                  f"- 公開日: {v['published_at'][:10]} / 長さ: {fmt_duration(v['duration_s'])} / 再生: {v['view_count']:,} / コメント: {v['comment_count']:,}",
                  f"- タグ: {', '.join(v['tags'][:20]) or '（なし）'}",
                  f"- 道名候補（概要欄・タグ）: {', '.join(v['road_candidates_description']) or '（抽出なし）'}",
                  f"- 道名候補（コメント）: {', '.join(v['road_candidates_comments']) or '（抽出なし）'}",
                  ""]
        if v["chapters"]:
            lines += ["### チャプター", ""] + [f"- {c['time']} {c['title']}" for c in v["chapters"]] + [""]
        lines += ["### 概要欄", "", "```", v["description"].strip() or "（空）", "```", ""]
        if v["comments_disabled"]:
            lines += ["### コメント", "", "（コメント無効）", ""]
        elif v["comments"]:
            lines += ["### コメント（関連度順・道に関係しそうなもの）", ""]
            for c in v["comments"]:
                if c["road_related"]:
                    lines.append(f"- {c['author']}: {c['text'][:300].replace(chr(10), ' ')}")
                    for r in c["replies"]:
                        lines.append(f"  - ↳ {r['author']}: {r['text'][:300].replace(chr(10), ' ')}")
            lines.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main() -> None:
    args = [extract_video_id(a) for a in sys.argv[1:]]
    ids = list(dict.fromkeys([i for i in args if i] or DEFAULT_VIDEO_IDS))
    print(f"{len(ids)} 本の動画情報を取得します…")
    videos = fetch_videos(ids)
    found = {v["id"] for v in videos}
    for missing in [i for i in ids if i not in found]:
        print(f"  取得できず（非公開または削除）: {missing}")

    road_words = re.compile(r"(道|峠|ライン|号|林道|ルート|コース|どこ|場所|トンネル|街道)")
    for v in videos:
        print(f"  {v['id']} {v['title'][:40]}")
        v["chapters"] = parse_chapters(v["description"])
        v["road_candidates_description"] = road_candidates(v["description"] + " " + " ".join(v["tags"]) + " " + v["title"])
        comments, disabled = fetch_comments(v["id"])
        v["comments_disabled"] = disabled
        for c in comments:
            full = c["text"] + " " + " ".join(r["text"] for r in c["replies"])
            c["road_related"] = bool(road_words.search(full))
        v["comments"] = comments
        v["road_candidates_comments"] = road_candidates(
            " ".join(c["text"] + " " + " ".join(r["text"] for r in c["replies"]) for c in comments if c["road_related"]))

    os.makedirs("out", exist_ok=True)
    stamp = date.today().strftime("%Y%m%d")
    json_path = os.path.join("out", f"{stamp}_youtube_videos.json")
    md_path = os.path.join("out", f"{stamp}_youtube_videos.md")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(videos, f, ensure_ascii=False, indent=2)
    write_markdown(videos, md_path)
    print(f"\n完了。次の 2 ファイルを作成しました。\n  {json_path}\n  {md_path}\n"
          "この 2 ファイルを git で push するか、.md の内容を Claude に貼り付けてください。")


if __name__ == "__main__":
    main()
