"""同じ道の重複統合。名前の正規化と、形状の重なりの 2 段階"""
import re
from .geo import haversine_m

SUFFIX_NOISE = ["（", "(", "【", "[", "〜", "~", "～"]


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


def overlap_ratio(a: list[tuple[float, float]], b: list[tuple[float, float]], tol_m: float = 250) -> float:
    """a の点のうち b の近くにある割合（粗い近似。点列は 15m 間引き済み）"""
    if not a or not b:
        return 0.0
    step_b = max(1, len(b) // 200)
    bs = b[::step_b]
    hit = 0
    step_a = max(1, len(a) // 150)
    sa = a[::step_a]
    for p in sa:
        if any(haversine_m(p, q) < tol_m for q in bs):
            hit += 1
    return hit / len(sa)


def find_duplicates(roads: list[dict]) -> list[tuple[int, int, float, bool]]:
    """同じ道とみなす組を返す (keep_id, drop_id, ratio, take_drop_geometry)。
    - 形状が互いに 80%/50% 以上重なる → 同じ道
    - 短い方が長い方に 80% 以上含まれる（志賀草津道路 20km と志賀草津高原ルート 44km など）→ 同じ道。長い方の形状を残す
    残す ID は言及数の多い方"""
    out = []
    geo = [(r["id"], r["_coords"], r["mentions"], r.get("length_m") or 0) for r in roads if r.get("_coords")]
    for i in range(len(geo)):
        for j in range(i + 1, len(geo)):
            ia, ca, ma, la = geo[i]
            ib, cb, mb, lb = geo[j]
            if abs(ca[0][1] - cb[0][1]) > 1.0 or abs(ca[0][0] - cb[0][0]) > 1.0:
                continue
            r1, r2 = overlap_ratio(ca, cb), overlap_ratio(cb, ca)  # r1: a の点が b の近くにある割合
            same = max(r1, r2) >= 0.8 and min(r1, r2) >= 0.5
            contained = (r1 >= 0.8 and la <= lb) or (r2 >= 0.8 and lb <= la)
            if not (same or contained):
                continue
            keep, drop = (ia, ib) if ma >= mb else (ib, ia)
            drop_len = lb if drop == ib else la
            keep_len = la if keep == ia else lb
            out.append((keep, drop, max(r1, r2), drop_len > keep_len * 1.2))
    return out
