"""同じ道の重複統合。名前の正規化と、形状の重なりの 2 段階"""
import re
from .geo import cell_of, overlap_ratio, resample, segment_index

SUFFIX_NOISE = ["（", "(", "【", "[", "〜", "~", "～"]

# 名前の差がこの語の有無だけなら、形が重なっても別の道として扱う。
# 「エサヌカ線」と「裏エサヌカ線」、「国道414号」と「国道414号 旧道」など
ASYMMETRIC_MARKERS = ("裏", "旧道", "新道", "第一", "第二", "第三", "上り", "下り")
# 片方の名前がもう片方を含み、その差が方位だけの場合も別の道。
# 「伊豆スカイライン」と「西伊豆スカイライン」、「ミルクロード」と「北19号ミルクロード」など
EDGE_RE = re.compile(r"^[東西南北](\d+号)?$")
ROAD_NUMBER_RE = re.compile(r"(国道|県道|都道|府道|道道)(\d+)号")
# 場所を特定しない道路の種別語。これだけが共通していても同じ道とは言えない
GENERIC_WORDS = {
    "ライン", "ロード", "街道", "道路", "林道", "農道", "広域農道", "スカイライン", "パノラマライン",
    "グリーンライン", "ブルーライン", "シーサイドライン", "海岸", "海岸線", "並木", "桜並木", "大橋",
    "周遊道路", "周回道路", "周遊線", "高原", "展望台", "有料道路", "ドライブウェイ", "バイパス",
    "峠", "県道", "国道", "トンネル", "湖畔", "アクセス道路", "ダム", "渓谷", "牧場",
}

# 名前の共通部分がこれだけでは、場所を特定したことにならない
PARTICLES = "のがとやへにをはも・、　 "

COARSE_TOL_M = 300.0     # 粗い絞り込み。取りこぼさないよう緩めに見る
COARSE_SCREEN = 0.45     # これを下回る組は本判定にかけず、形が別物として扱う
FINE_TOL_M = 120.0       # 本判定
FINE_FLOOR = 0.8         # 同じ道とみなす重なりの下限
FINE_FLOOR_STRONG = 0.6  # 名前がほぼ一致している組はここまで緩める
CONFLICT_MAX = 0.4       # これを下回る重なりで名前が一致する組は、区間の誤りとして報告する
COARSE_POINTS = 20


def normalize_name(name: str) -> str:
    n = name.strip()
    for s in SUFFIX_NOISE:
        if s in n:
            n = n.split(s)[0]
    n = re.sub(r"\s+", "", n)
    n = n.replace("ヶ", "ケ").replace("ケ", "ヶ")  # 表記ゆれを片側に寄せる
    n = re.sub(r"(国道|県道|都道|府道|道道|R|r)\s?(\d+)\s?(号線|号)?", lambda m: f"{'国道' if m.group(1) in ('国道','R','r') else m.group(1)}{m.group(2)}号", n)
    n = n.replace("ライン", "ライン").replace("ロード", "ロード")
    return n.lower()


def road_key(road: dict) -> str:
    """通称があれば通称、無ければ路線番号＋都道府県で同一視する"""
    name = normalize_name(road.get("name", ""))
    number = normalize_name(road.get("road_number", "") or "")
    pref = (road.get("prefecture") or "").replace("県", "").replace("府", "").replace("都", "").replace("道", "")[:3]
    if name and not re.fullmatch(r"(国道|県道|都道|府道|道道)\d+号", name):
        return f"name:{name}"
    if number:
        return f"num:{number}:{pref}"
    return f"name:{name}:{pref}"


def _road_numbers(name: str) -> set[str]:
    return {m.group(1) + m.group(2) for m in ROAD_NUMBER_RE.finditer(name)}


def distinct_by_name(a: str, b: str) -> bool:
    """名前の差が区別語（裏・旧道・方位）だけ、または路線番号が違うなら別の道"""
    for m in ASYMMETRIC_MARKERS:
        if (m in a) != (m in b):
            return True
    na, nb = _road_numbers(a), _road_numbers(b)
    if na and nb and not (na & nb):
        return True
    short, long = sorted((a, b), key=len)
    if short and short != long and short in long:
        extra = re.sub(r"[\s・（）()【】\[\]]", "", long.replace(short, "", 1))
        if EDGE_RE.match(extra):
            return True
    return False


def longest_common_substring(a: str, b: str) -> str:
    if not a or not b:
        return ""
    prev = [0] * (len(b) + 1)
    best = end = 0
    for i in range(1, len(a) + 1):
        cur = [0] * (len(b) + 1)
        for j in range(1, len(b) + 1):
            if a[i - 1] == b[j - 1]:
                cur[j] = prev[j - 1] + 1
                if cur[j] > best:
                    best, end = cur[j], i
        prev = cur
    return a[end - best:end]


def distinctive_part(s: str) -> str:
    """名前から、場所を特定しない種別語と助詞を取り除いた部分。
    「の林道」→「」、「林道長」→「長」、「ミルクロード」→「ミルク」"""
    for w in sorted(GENERIC_WORDS, key=len, reverse=True):
        s = s.replace(w, "")
    return "".join(ch for ch in s if ch not in PARTICLES)


def name_relation(a: str, b: str) -> str:
    """同じ道の呼び分けとみなせる名前かを 3 段階で返す。
    strong: 短い方の名前がほぼそのまま含まれる（「美幌峠」と「国道243号 美幌峠」）
    related: 場所を示す語を共有する（「ミルクロード」と「阿蘇ミルクロード」）
    none: 共有するのが種別語や助詞だけ（「林道川乗線」と「林道日向沢線」）"""
    s = longest_common_substring(a, b)
    if len(s) < 3 or len(distinctive_part(s)) < 2:
        return "none"
    share = len(s) / min(len(a), len(b))
    if share >= 0.6:
        return "strong"
    return "related" if share >= 0.35 else "none"


def _thin(points: list, n: int) -> list:
    if len(points) <= n:
        return points
    step = len(points) / n
    return [points[int(i * step)] for i in range(n)]


def _prepare(roads: list[dict]) -> list[dict]:
    items = []
    for r in roads:
        coords = r.get("_coords")
        if not coords or len(coords) < 2:
            continue
        samples = resample(coords)
        items.append({"id": r["id"], "mentions": r["mentions"] or 0, "length_m": r.get("length_m") or 0,
                      "name": r.get("name") or "", "key": normalize_name(r.get("name") or ""),
                      "status": r.get("geo_status") or "ok", "samples": samples,
                      "coarse": _thin(samples, COARSE_POINTS), "index": segment_index(coords),
                      "cells": {cell_of(p) for p in samples}})
    return items


def _candidate_pairs(items: list[dict]) -> set[tuple[int, int]]:
    """同じ升目を通る組だけを候補にする。離れた場所の同名道（熊本と北海道のミルクロード）は
    ここで候補から外れる"""
    cells: dict = {}
    for i, it in enumerate(items):
        for c in it["cells"]:
            cells.setdefault(c, []).append(i)
    pairs = set()
    for ids in cells.values():
        if len(ids) < 2:
            continue
        for x in range(len(ids)):
            for y in range(x + 1, len(ids)):
                pairs.add((ids[x], ids[y]))
    return pairs


def _coarse_overlap(a: dict, b: dict) -> float:
    return max(overlap_ratio(a["coarse"], b["index"], COARSE_TOL_M),
               overlap_ratio(b["coarse"], a["index"], COARSE_TOL_M))


def _is_same_road(r1: float, r2: float, la: float, lb: float, floor: float) -> bool:
    """形が互いに沿っているか、短い方が長い方にすっかり含まれているか"""
    same = max(r1, r2) >= floor and min(r1, r2) >= 0.5
    contained = (r1 >= floor and la <= lb) or (r2 >= floor and lb <= la)
    return same or contained


def analyze(roads: list[dict]) -> tuple[list[tuple[int, int, float, bool]], list[tuple[str, str, float]]]:
    """統合する組と、確認が必要な組をまとめて返す。

    統合する組 (keep_id, drop_id, ratio, take_drop_geometry):
      形が同じ、または短い方が長い方に含まれ、かつ名前も同じ道を指しているもの。
      残す ID は言及数の多い方。形状は、確定済みで極端に長くない方を採る。
    確認が必要な組 (name_a, name_b, ratio):
      近くにあって名前は同じ道を指しているのに、形がほとんど重なっていないもの。
      どちらかの区間が間違っている合図（「ミルクロード」の始点が米塚になっていた例など）"""
    items = _prepare(roads)
    dups, conflicts = [], []
    for i, j in sorted(_candidate_pairs(items)):
        a, b = items[i], items[j]
        if distinct_by_name(a["key"], b["key"]):
            continue
        rel = name_relation(a["key"], b["key"])
        if rel == "none":
            continue
        coarse = _coarse_overlap(a, b)
        if coarse < COARSE_SCREEN:
            conflicts.append((a["name"], b["name"], coarse))
            continue
        r1 = overlap_ratio(a["samples"], b["index"], FINE_TOL_M)
        r2 = overlap_ratio(b["samples"], a["index"], FINE_TOL_M)
        floor = FINE_FLOOR_STRONG if rel == "strong" else FINE_FLOOR
        if not _is_same_road(r1, r2, a["length_m"], b["length_m"], floor):
            if max(r1, r2) < CONFLICT_MAX:
                conflicts.append((a["name"], b["name"], max(r1, r2)))
            continue
        keep, drop = (a, b) if a["mentions"] >= b["mentions"] else (b, a)
        # 形状は確定済みの方を採る。残す側が要確認なら差し替え、そうでなければ
        # 1.2〜3 倍までの長い形状に限って採用する（連結された別ルートを取り込まないため）
        take = (drop["status"] == "ok" and keep["length_m"] > 0
                and (keep["status"] == "suspect"
                     or keep["length_m"] * 1.2 < drop["length_m"] <= keep["length_m"] * 3))
        dups.append((keep["id"], drop["id"], max(r1, r2), take))
    dups.sort(key=lambda t: -t[2])
    conflicts.sort(key=lambda t: t[2])
    return dups, conflicts
