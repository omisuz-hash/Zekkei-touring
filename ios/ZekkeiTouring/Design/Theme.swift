import SwiftUI

// MARK: - 配色（デザイン v2 ダーク。docs/design/20260905_v2_dark を正とする）

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum ZK {
    // 地
    static let bg = Color(hex: 0x0B0E11)          // フォーム系画面の背景
    static let panel = Color(hex: 0x0B1A23)       // パネル地
    static let mapBase = Color(hex: 0x111815)
    static let card = Color(hex: 0x14181C, alpha: 0.86)
    static let glass = Color(hex: 0x14181C, alpha: 0.82)
    static let group = Color.white.opacity(0.05)
    static let groupThin = Color.white.opacity(0.04)
    // 枠
    static let border = Color.white.opacity(0.07)
    static let divider = Color.white.opacity(0.06)
    static let chipBorder = Color.white.opacity(0.14)
    // アクセント
    static let tagBg = Color(hex: 0x0F2A38)
    static let accent = Color(hex: 0x5FB4DD)      // タグ枠・リンク
    static let primaryButton = Color(hex: 0xE9F6FC)
    static let primaryButtonText = Color(hex: 0x0B1A23)
    // 絶景度 3 段階
    static let tier1 = Color(hex: 0x8ED4F5)       // 4.5 以上
    static let tier2 = Color(hex: 0x1B9BD6)       // 3.5 以上
    static let tier3 = Color(hex: 0x7C8B95)       // 評価が少ない
    // 文字
    static let text = Color.white
    static let body = Color(hex: 0xC5CED3)
    static let caption = Color(hex: 0x8F9BA3)
    static let disabled = Color(hex: 0x5C6A73)
    static let tabInactive = Color(hex: 0x6E7C85)
    // 状態
    static let danger = Color(hex: 0xFF453A)
    static let errorText = Color(hex: 0xFF6B61)
    static let paused = Color(hex: 0xFFD166)

    /// 絶景度から線の色
    static func tier(scenery: Double?, count: Int) -> Color {
        guard let s = scenery, count > 0 else { return tier3 }
        if s >= 4.5 { return tier1 }
        if s >= 3.5 { return tier2 }
        return tier3
    }
}

// MARK: - 文字

extension Font {
    /// キャプション（8〜10pt、字間広め）
    static func zkCaption(_ size: CGFloat = 9) -> Font { .system(size: size, weight: .semibold) }
    static func zkNumber(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .default).monospacedDigit() }
}

struct CaptionLabel: View {
    let text: String
    var size: CGFloat = 9
    var body: some View {
        Text(text).font(.zkCaption(size)).tracking(size * 0.12).foregroundStyle(ZK.caption).textCase(.uppercase)
    }
}

// MARK: - 部品

/// 半透明カード（地図の上に載る）
struct GlassCard: ViewModifier {
    var radius: CGFloat = 22
    var padding: EdgeInsets = EdgeInsets(top: 14, leading: 18, bottom: 20, trailing: 18)
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ZK.card)
            .background(.ultraThinMaterial.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(ZK.border, lineWidth: 1))
    }
}

extension View {
    func glassCard(radius: CGFloat = 22, padding: EdgeInsets = EdgeInsets(top: 14, leading: 18, bottom: 20, trailing: 18)) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }
    /// 小物用のガラス（検索バー、ボタン、ピル）
    func glassPill(radius: CGFloat = 14) -> some View {
        self.background(ZK.glass)
            .background(.ultraThinMaterial.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(ZK.border, lineWidth: 1))
    }
    /// 内側グループ（rgba 255,255,255,.04〜.05）
    func innerGroup(radius: CGFloat = 12, thin: Bool = false) -> some View {
        self.background(thin ? ZK.groupThin : ZK.group)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 主ボタン（明るい地・濃い文字）
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    var radius: CGFloat = 14
    var font: Font = .system(size: 15, weight: .bold)
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(isEnabled ? ZK.primaryButtonText : ZK.caption)
            .background(isEnabled ? ZK.primaryButton : Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// 危険操作のボタン（記録を終了など）
struct DangerButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    var radius: CGFloat = 14
    var font: Font = .system(size: 15, weight: .bold)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(.white)
            .background(ZK.danger)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// 空港コード風タグ（▶ VENUS / ★ R142）
struct CodeTag: View {
    let code: String
    var fromVideo: Bool = true
    var muted: Bool = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: fromVideo ? "play.fill" : "star.fill").font(.system(size: 8, weight: .bold))
            Text(code).font(.system(size: 10, weight: .bold)).tracking(0.5)
        }
        .foregroundStyle(muted ? ZK.caption : .white)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(muted ? Color(hex: 0x1A2126) : ZK.tagBg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(muted ? ZK.tier3 : ZK.accent, lineWidth: 1.2))
    }
}

/// 数値タイル（キャプション → 大きな数値 → 補足）
struct StatTile: View {
    let caption: String
    let value: String
    var unit: String? = nil
    var note: String? = nil
    var valueColor: Color = .white
    var valueSize: CGFloat = 26
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CaptionLabel(text: caption)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.zkNumber(valueSize)).foregroundStyle(valueColor)
                if let unit { Text(unit).font(.system(size: 12)).foregroundStyle(ZK.caption) }
            }
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(ZK.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .innerGroup(radius: 12, thin: true)
    }
}

/// 5 軸バー
struct AxisBar: View {
    let title: String
    let value: Double?
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(ZK.body).frame(width: 124, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    if let v = value {
                        Capsule().fill(ZK.accent).frame(width: g.size.width * CGFloat(min(max(v / 5, 0), 1)))
                    }
                }
            }
            .frame(height: 3)
            Text(value.map { String(format: "%.1f", $0) } ?? "–").font(.zkNumber(12)).foregroundStyle(.white).frame(width: 28, alignment: .trailing)
        }
    }
}

/// 注意タグ（冬季閉鎖 = 青、渋滞など = 枠のみ）
struct CautionTag: View {
    let text: String
    var filled: Bool = true
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? .white : ZK.body)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filled ? ZK.tagBg : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(filled ? ZK.accent : ZK.chipBorder, lineWidth: 1))
    }
}

/// 選択チップ（季節など）
struct Chip: View {
    let text: String
    let selected: Bool
    var body: some View {
        Text(text).font(.system(size: 13, weight: .bold))
            .foregroundStyle(selected ? .white : ZK.body)
            .frame(height: 36).padding(.horizontal, 14)
            .background(selected ? ZK.tagBg : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? ZK.accent : ZK.chipBorder, lineWidth: 1))
    }
}

/// 状態ドット（記録中は点滅）
struct StatusDot: View {
    let color: Color
    var pulse: Bool = false
    @State private var on = true
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(pulse ? (on ? 1 : 0.35) : 1)
            .onAppear {
                guard pulse else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on.toggle() }
            }
    }
}

/// 5 段階の星（タップ領域 34×44、選択は Tidal blue）
struct StarPicker: View {
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: "star.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(i <= value ? ZK.tier1 : Color.white.opacity(0.14))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { value = i }
            }
        }
    }
}

/// 道の短いコード（マーカー用）。路線番号があれば R152 / K25、無ければ名前の先頭
extension ZekkeiRoad {
    var shortCode: String {
        let n = name
        if let m = n.range(of: #"国道\s?(\d{1,4})"#, options: .regularExpression) {
            return "R" + n[m].filter { $0.isNumber }
        }
        if let m = n.range(of: #"(県道|都道|府道|道道)\s?(\d{1,4})"#, options: .regularExpression) {
            return "K" + n[m].filter { $0.isNumber }
        }
        let base = n.components(separatedBy: CharacterSet(charactersIn: "（(【[〜~・ ")).first ?? n
        return String(base.prefix(5))
    }
}
