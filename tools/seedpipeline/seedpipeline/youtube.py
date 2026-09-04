"""YouTube Data API v3。利用枠（ユニット）を数えながら呼ぶ"""
import re
from .http import request, HTTPError

API = "https://www.googleapis.com/youtube/v3"
COST = {"search": 100, "videos": 1, "commentThreads": 1, "playlistItems": 1, "channels": 1}


class QuotaExceeded(Exception):
    pass


class YouTube:
    def __init__(self, api_key: str, budget_units: int, used_units: int = 0):
        self.key = api_key
        self.budget = budget_units
        self.used = used_units

    def _get(self, resource: str, params: dict) -> dict:
        cost = COST[resource]
        if self.used + cost > self.budget:
            raise QuotaExceeded(f"本日の予算 {self.budget} ユニットに達しました（使用 {self.used}）")
        try:
            data = request(f"{API}/{resource}", params={**params, "key": self.key})
        except HTTPError as e:
            if e.status == 403 and "quota" in e.body.lower():
                raise QuotaExceeded("YouTube API の 1 日の利用枠を使い切りました")
            if e.status == 403 and "commentsDisabled" in e.body:
                return {"items": [], "_disabled": True}
            raise
        self.used += cost
        return data

    def search(self, query: str, page_token: str | None = None, order: str = "relevance") -> tuple[list[dict], str | None]:
        params = {"part": "snippet", "type": "video", "q": query, "maxResults": 50, "regionCode": "JP",
                  "relevanceLanguage": "ja", "order": order, "videoDuration": "any", "safeSearch": "none"}
        if page_token:
            params["pageToken"] = page_token
        data = self._get("search", params)
        items = [{"id": it["id"]["videoId"], "title": it["snippet"]["title"], "channel_id": it["snippet"]["channelId"],
                  "channel": it["snippet"]["channelTitle"], "published_at": it["snippet"]["publishedAt"]}
                 for it in data.get("items", []) if it.get("id", {}).get("videoId")]
        return items, data.get("nextPageToken")

    def videos(self, ids: list[str]) -> list[dict]:
        out = []
        for i in range(0, len(ids), 50):
            data = self._get("videos", {"part": "snippet,contentDetails,statistics", "id": ",".join(ids[i:i + 50])})
            for it in data.get("items", []):
                sn, cd, st = it["snippet"], it.get("contentDetails", {}), it.get("statistics", {})
                out.append({
                    "id": it["id"], "title": sn.get("title", ""), "channel": sn.get("channelTitle", ""),
                    "channel_id": sn.get("channelId", ""), "published_at": sn.get("publishedAt", ""),
                    "duration_s": parse_duration(cd.get("duration", "")),
                    "view_count": int(st.get("viewCount", 0) or 0), "like_count": int(st.get("likeCount", 0) or 0),
                    "comment_count": int(st.get("commentCount", 0) or 0),
                    "tags": sn.get("tags", []), "description": sn.get("description", ""),
                    "thumbnail": (sn.get("thumbnails", {}).get("maxres") or sn.get("thumbnails", {}).get("high") or {}).get("url", ""),
                    "default_language": sn.get("defaultAudioLanguage") or sn.get("defaultLanguage") or "",
                })
        return out

    def comments(self, video_id: str, limit: int = 60) -> list[dict]:
        data = self._get("commentThreads", {"part": "snippet,replies", "videoId": video_id, "maxResults": min(100, limit),
                                            "order": "relevance", "textFormat": "plainText"})
        out = []
        for th in data.get("items", []):
            top = th["snippet"]["topLevelComment"]["snippet"]
            out.append({"author": top.get("authorDisplayName", ""), "text": top.get("textDisplay", ""),
                        "likes": top.get("likeCount", 0),
                        "replies": [r["snippet"].get("textDisplay", "") for r in th.get("replies", {}).get("comments", [])]})
        return out

    def channel_uploads_playlist(self, channel_id: str) -> str | None:
        data = self._get("channels", {"part": "contentDetails", "id": channel_id})
        items = data.get("items", [])
        return items[0]["contentDetails"]["relatedPlaylists"]["uploads"] if items else None

    def playlist_video_ids(self, playlist_id: str, max_items: int = 200) -> list[str]:
        ids, token = [], None
        while len(ids) < max_items:
            params = {"part": "contentDetails", "playlistId": playlist_id, "maxResults": 50}
            if token:
                params["pageToken"] = token
            data = self._get("playlistItems", params)
            ids += [it["contentDetails"]["videoId"] for it in data.get("items", [])]
            token = data.get("nextPageToken")
            if not token:
                break
        return ids[:max_items]


def parse_duration(iso: str) -> int:
    m = re.fullmatch(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", iso or "")
    if not m:
        return 0
    h, mi, s = (int(x or 0) for x in m.groups())
    return h * 3600 + mi * 60 + s


def parse_chapters(description: str) -> list[dict]:
    out = []
    for line in description.splitlines():
        m = re.match(r"\s*\(?(\d{1,2}:\d{2}(?::\d{2})?)\)?\s*[\-–—:：]?\s*(.+)", line)
        if m:
            out.append({"time": m.group(1), "title": m.group(2).strip()})
    return out


def looks_like_touring(video: dict) -> bool:
    """明らかに対象外の動画を安価に除外する（用品レビュー、納車、事故、ゲーム等）"""
    t = (video.get("title", "") + " " + " ".join(video.get("tags", []))).lower()
    bad = ["納車", "レビュー", "インプレ", "カスタム", "整備", "洗車", "事故", "煽り", "ドラレコ", "ゲーム", "grand theft", "ride 4", "教習",
           "免許", "売却", "査定", "保険", "用品", "ヘルメット", "ジャケット", "グローブ", "開封", "比較"]
    good = ["ツーリング", "モトブログ", "絶景", "峠", "ライン", "街道", "林道", "ロード", "快走", "景色", "旅"]
    if any(b in t for b in bad) and not any(g in t for g in good):
        return False
    return any(g in t for g in good)
