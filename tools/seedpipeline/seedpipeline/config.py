import os
from dataclasses import dataclass, field


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


@dataclass
class Config:
    youtube_api_key: str = field(default_factory=lambda: _env("YOUTUBE_API_KEY"))
    gemini_api_key: str = field(default_factory=lambda: _env("GEMINI_API_KEY"))
    gemini_model: str = field(default_factory=lambda: _env("GEMINI_MODEL", "gemini-3.6-flash"))
    google_maps_api_key: str = field(default_factory=lambda: _env("GOOGLE_MAPS_API_KEY"))
    # Geocoding と Routes でキーを分けた場合はこちら（未設定なら GOOGLE_MAPS_API_KEY を両方に使う）
    google_geocoding_api_key: str = field(default_factory=lambda: _env("GOOGLE_GEOCODING_API_KEY") or _env("GOOGLE_MAPS_API_KEY"))
    google_routes_api_key: str = field(default_factory=lambda: _env("GOOGLE_ROUTES_API_KEY") or _env("GOOGLE_MAPS_API_KEY"))
    # geo: "google"（Geocoding + Routes API。課金登録が必要だが無料枠あり）/ "osm"（OpenStreetMap。無料・キー不要・精度は落ちる）
    geo_provider: str = field(default_factory=lambda: _env("GEO_PROVIDER", "google" if (_env("GOOGLE_MAPS_API_KEY") or _env("GOOGLE_ROUTES_API_KEY")) else "osm"))
    db_path: str = field(default_factory=lambda: _env("SEED_DB", "out/seedpipeline.sqlite"))

    # 1 日の YouTube API 利用枠（既定 10,000 ユニット）のうち、このツールが使う上限
    youtube_daily_budget: int = field(default_factory=lambda: int(_env("SEED_YT_BUDGET", "9000")))
    # 1 回の実行で処理する動画の上限（環境変数 SEED_MAX_VIDEOS で変更可）
    max_videos_per_run: int = field(default_factory=lambda: int(_env("SEED_MAX_VIDEOS", "300")))
    # 映像解析（Gemini に YouTube URL を渡す）を使う上限本数/実行。無料枠は 1 日 8 時間分が目安
    max_video_analyses_per_run: int = field(default_factory=lambda: int(_env("SEED_MAX_VIDEO_ANALYSES", "20")))
    # 1 回の実行で形状を付ける道の上限
    max_geo_per_run: int = field(default_factory=lambda: int(_env("SEED_MAX_GEO", "600")))
    max_spots_per_run: int = field(default_factory=lambda: int(_env("SEED_MAX_SPOTS", "300")))
    max_photos_per_run: int = field(default_factory=lambda: int(_env("SEED_MAX_PHOTOS", "400")))
    max_respot_per_run: int = field(default_factory=lambda: int(_env("SEED_MAX_RESPOT", "400")))
    max_wiki_per_run: int = field(default_factory=lambda: int(_env("SEED_MAX_WIKI", "300")))
    # 当たりチャンネルの投稿一覧を 1 回の実行でたどる数
    channels_per_run: int = field(default_factory=lambda: int(_env("SEED_CHANNELS_PER_RUN", "5")))
    # 動画の長さ（秒）。短すぎる（Shorts）と長すぎる（生配信）は除外
    min_duration_s: int = 180
    max_duration_s: int = 3 * 3600

    search_keywords: list[str] = field(default_factory=lambda: [
        "絶景 ツーリング", "景色 ツーリング", "景色の良い道 ツーリング", "のどかな道 バイクツーリング",
        "絶景ロード バイク", "快走路 ツーリング", "ワインディング ツーリング 絶景", "峠 ツーリング 絶景",
        "スカイライン バイク ツーリング", "高原 ツーリング バイク", "海沿い ツーリング バイク 絶景",
        "林道 ツーリング 絶景", "穴場 ツーリング バイク", "田舎道 ツーリング", "モトブログ 絶景",
        "ツーリング おすすめ ルート 絶景", "日本の絶景道 バイク", "ツーリング 気持ちいい道",
        "北海道 ツーリング 絶景", "東北 ツーリング 絶景", "関東 ツーリング 絶景", "信州 ツーリング 絶景",
        "北陸 ツーリング 絶景", "東海 ツーリング 絶景", "関西 ツーリング 絶景", "中国地方 ツーリング 絶景",
        "四国 ツーリング 絶景", "九州 ツーリング 絶景", "沖縄 ツーリング 絶景",
    ])
    # 検索 1 キーワードあたりのページ数（1 ページ 50 件・100 ユニット）
    search_pages_per_keyword: int = 2

    def require(self, *names: str) -> None:
        missing = [n for n in names if not getattr(self, n)]
        if missing:
            envs = {"youtube_api_key": "YOUTUBE_API_KEY", "gemini_api_key": "GEMINI_API_KEY", "google_maps_api_key": "GOOGLE_MAPS_API_KEY"}
            raise SystemExit("環境変数が未設定です: " + ", ".join(envs.get(n, n) for n in missing))
