"""Gemini API。テキスト（概要欄・コメント）からの道の抽出と、YouTube 動画そのものの解析"""
import json
import time
from .http import request, HTTPError

API = "https://generativelanguage.googleapis.com/v1beta"

ROAD_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "is_touring_ride": {"type": "BOOLEAN", "description": "バイクで実際に道を走るツーリング動画か"},
        "prefectures": {"type": "ARRAY", "items": {"type": "STRING"}},
        "roads": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "name": {"type": "STRING", "description": "道の通称または正式名（例: ビーナスライン、国道411号 大菩薩ライン）"},
                    "road_number": {"type": "STRING", "description": "国道/県道番号があれば（例: 国道152号、県道25号）。無ければ空"},
                    "prefecture": {"type": "STRING"},
                    "start_label": {"type": "STRING", "description": "区間の始点となる地名・施設名。地図検索できる具体名"},
                    "start_municipality": {"type": "STRING", "description": "始点の市区町村名（例: 奥多摩町、甲州市）。分からなければ空"},
                    "end_label": {"type": "STRING", "description": "区間の終点となる地名・施設名"},
                    "end_municipality": {"type": "STRING", "description": "終点の市区町村名。分からなければ空"},
                    "approx_length_km": {"type": "NUMBER", "description": "この区間のおおよその距離 km（一般知識で可）。分からなければ 0"},
                    "via_labels": {"type": "ARRAY", "items": {"type": "STRING"}, "description": "経由地（峠、道の駅、展望台など）最大4つ"},
                    "timestamp": {"type": "STRING", "description": "動画内でこの道が登場する時刻 mm:ss。不明なら空"},
                    "scenery_hint": {"type": "INTEGER", "description": "景色の良さの示唆 1-5"},
                    "winding_hint": {"type": "INTEGER", "description": "カーブの多さの示唆 1-5"},
                    "surface_hint": {"type": "INTEGER", "description": "路面・道幅の良さの示唆 1-5（未舗装は1）"},
                    "rest_hint": {"type": "INTEGER", "description": "休憩所（道の駅・売店・トイレ）の示唆 1-5"},
                    "parking_hint": {"type": "INTEGER", "description": "絶景地点で停められる示唆 1-5"},
                    "season": {"type": "STRING"},
                    "cautions": {"type": "STRING", "description": "冬季閉鎖、通行止め、二輪通行禁止、観光渋滞など"},
                    "summary": {"type": "STRING", "description": "この道の魅力を 1-2 文で"},
                    "confidence": {"type": "NUMBER", "description": "この道を実際に走った確度 0-1"},
                    "evidence": {"type": "STRING", "description": "根拠となった記述の引用（短く）"},
                },
                "required": ["name", "prefecture", "start_label", "end_label", "confidence"],
            },
        },
    },
    "required": ["is_touring_ride", "roads"],
}

SYSTEM = """あなたは日本のバイクツーリング動画から「走った道の区間」を抽出する専門家です。
目的は、ライダーに「この道は走ると景色が良くて気持ちいい」と案内するデータベースを作ることです。
ルール:
- 実際に走行した道だけを抽出する。目的地（神社、宿、飲食店）や登山道は道として扱わない。
- 高速道路・都市部の移動区間は除外する。
- 道の名前は通称（〇〇ライン、〇〇街道、〇〇みち）を優先し、国道/県道番号があれば road_number に入れる。
- 始点・終点は Google マップで検索できる具体的な地名・施設名にする（例: 「道の駅たばやま」「柳沢峠」「白樺湖」）。市町村名だけでも可。
- 始点・終点には必ず市区町村名（start_municipality / end_municipality）を添える。同名の地名が各地にあるため、これが無いと別の場所に飛ぶ。
- 区間は「その道として走って気持ちいい部分」に絞る。国道全体（例: 国道152号の全長）ではなく、通称で呼ばれる区間や峠の前後にする。
- approx_length_km には、その区間の一般に知られる距離を入れる（例: 奥多摩周遊道路 ≒ 20、ビーナスライン全線 ≒ 76）。
- 経由地は峠・道の駅・展望台・橋など、道路の形状を決めるのに役立つ地点を選ぶ。
- 1 つの動画に複数の道があれば全て列挙する。チャプターの時刻を timestamp に入れる。
- 視聴者コメントで地元の呼び名や隣の穴場が語られていれば、動画の道の補足（name に併記）または別の道として confidence を下げて列挙する。
- 分からない項目は空にし、推測で埋めない。"""


class Gemini:
    def __init__(self, api_key: str, model: str = "gemini-3.6-flash"):
        self.key = api_key
        self.model = model
        self.calls = 0

    def _generate(self, parts: list[dict], schema: dict | None = None, temperature: float = 0.2) -> dict:
        body = {
            "system_instruction": {"parts": [{"text": SYSTEM}]},
            "contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": temperature, "maxOutputTokens": 8192},
        }
        if schema:
            body["generationConfig"]["response_mime_type"] = "application/json"
            body["generationConfig"]["response_schema"] = schema
        for attempt in range(3):
            try:
                data = request(f"{API}/models/{self.model}:generateContent", method="POST", body=body,
                               headers={"x-goog-api-key": self.key}, timeout=300)
                break
            except HTTPError as e:
                if e.status == 429 and attempt < 2:
                    time.sleep(30 * (attempt + 1))
                    continue
                raise
        self.calls += 1
        cands = data.get("candidates") or []
        if not cands or "content" not in cands[0]:
            return {"is_touring_ride": False, "roads": [], "_blocked": data.get("promptFeedback")}
        text = "".join(p.get("text", "") for p in cands[0]["content"].get("parts", []))
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {"is_touring_ride": False, "roads": [], "_raw": text[:500]}

    def extract_from_text(self, video: dict, comments: list[dict]) -> dict:
        chapters = "\n".join(f"{c['time']} {c['title']}" for c in video.get("chapters", []))
        cm = "\n".join(f"- {c['text'][:300]}" + "".join(f"\n  ↳ {r[:200]}" for r in c.get("replies", [])[:2])
                       for c in comments[:40])
        text = f"""# 動画
タイトル: {video['title']}
チャンネル: {video['channel']}
長さ: {video.get('duration_s', 0) // 60} 分 / 再生数: {video.get('view_count', 0)}
タグ: {', '.join(video.get('tags', [])[:20])}

# 概要欄
{video.get('description', '')[:4000]}

# チャプター
{chapters or '（なし）'}

# 視聴者コメント（関連度順）
{cm or '（なし）'}

上記から走った道の区間を JSON で抽出してください。"""
        return self._generate([{"text": text}], ROAD_SCHEMA)

    def extract_from_video(self, video_url: str, video: dict) -> dict:
        """YouTube の公開動画を Gemini に直接見せて抽出する（概要欄が乏しい動画向け）"""
        text = f"""この動画（タイトル: {video['title']}）を視聴し、走行している道の区間を JSON で抽出してください。
画面内の道路標識・案内標識・字幕・テロップ・地名の看板から、道の名前と番号、通過した地名を読み取ってください。
道が登場する時刻を timestamp に入れてください。"""
        return self._generate([{"file_data": {"file_uri": video_url}}, {"text": text}], ROAD_SCHEMA)

    def ping(self) -> str:
        """モデルが実際に使えるかを最小の呼び出しで確かめる"""
        body = {"contents": [{"role": "user", "parts": [{"text": "「OK」とだけ答えてください"}]}],
                "generationConfig": {"temperature": 0, "maxOutputTokens": 50}}
        data = request(f"{API}/models/{self.model}:generateContent", method="POST", body=body,
                       headers={"x-goog-api-key": self.key}, timeout=60)
        cands = data.get("candidates") or []
        text = "".join(p.get("text", "") for p in cands[0]["content"].get("parts", [])) if cands else ""
        return text.strip()[:20] or "(空の応答)"

    def list_models(self) -> list[str]:
        data = request(f"{API}/models", headers={"x-goog-api-key": self.key})
        return [m["name"].split("/")[-1] for m in data.get("models", []) if "generateContent" in m.get("supportedGenerationMethods", [])]
