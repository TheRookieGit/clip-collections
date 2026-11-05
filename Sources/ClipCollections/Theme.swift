import AppKit
import ClipCapture
import SwiftUI

/// 剪报档案: paper, ink and one vermilion. Every colour has a light (paper) and a dark (night reading) value.
enum Ink {
    static func tone(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let hex = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
    static let paper = tone(0xF5F0E6, 0x1B1916)
    static let sheet = tone(0xFAF6EE, 0x211F1B)
    static let selected = tone(0xEBE3D3, 0x2E2A24)
    static let hover = tone(0xF0EADD, 0x26231F)
    static let text = tone(0x221E18, 0xECE5D8)
    static let soft = tone(0x6D665A, 0xA49C8E)
    static let faint = tone(0x8F8778, 0x7D766A)
    static let line = tone(0xDAD2C2, 0x38342D)
    static let strong = tone(0x221E18, 0xCFC8BA)
    static let seal = tone(0xB23A2A, 0xE2694F)
    static let onSeal = tone(0xFBF6EA, 0x1B1916)
    static let ochre = tone(0x96660F, 0xDDA94F)
    static let notice = tone(0xF0E4CE, 0x332B1E)
}

enum Type {
    static func title(_ size: CGFloat) -> Font { .custom("STSongti-SC-Bold", size: size) }
    static func heavy(_ size: CGFloat) -> Font { .custom("STSongti-SC-Black", size: size) }
    static func serif(_ size: CGFloat) -> Font { .custom("STSongti-SC-Regular", size: size) }
}

extension ClipStatus {
    var ink: Color {
        switch self {
        case .pending: return Ink.faint
        case .processing: return Ink.soft
        case .saved: return Ink.seal
        case .incomplete: return Ink.ochre
        case .failed: return Ink.text
        }
    }
}

/// The status as a seal pressed onto the page. 待保存 is only an outline waiting to be stamped; 失败 is solid ink.
struct Stamp: View {
    let status: ClipStatus
    var large = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        Text(status.label)
            .font(Type.title(large ? 14 : 11))
            .kerning(large ? 2 : 1)
            .foregroundStyle(status == .failed ? Ink.paper : status.ink)
            .padding(.horizontal, large ? 9 : 6)
            .padding(.vertical, large ? 4 : 2)
            .background { if status == .failed { shape.fill(Ink.strong) } }
            .overlay {
                if status == .pending { shape.strokeBorder(status.ink, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                else if status != .failed { shape.strokeBorder(status.ink, lineWidth: status == .saved ? 1.5 : 1) }
            }
            .rotationEffect(.degrees(status == .saved ? -3 : 0))
            .fixedSize()
            .accessibilityLabel("状态：\(status.label)")
    }
}

struct Rule: View {
    var color = Ink.line
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// The masthead's thick-and-thin line, as under a newspaper's name.
struct DoubleRule: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Ink.strong).frame(height: 2)
            Rectangle().fill(Ink.strong).frame(height: 0.5)
        }
    }
}

/// The one strong action on a page.
struct SealButton: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(Type.title(13)).kerning(1).foregroundStyle(Ink.onSeal)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 2).fill(Ink.seal))
            .opacity(c.isPressed ? 0.8 : 1)
    }
}

struct PlainAction: ButtonStyle {
    var color = Ink.text
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.system(size: 12.5)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Ink.line, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(c.isPressed ? 0.6 : 1)
    }
}

struct TextAction: ButtonStyle {
    var color = Ink.soft
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.system(size: 12.5)).foregroundStyle(color).contentShape(Rectangle()).opacity(c.isPressed ? 0.6 : 1)
    }
}

enum Dates {
    private static let cn = Locale(identifier: "zh_CN")
    static func masthead(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = cn; f.dateFormat = "M月d日 EEEE"
        return f.string(from: d)
    }
    /// The heading of a day in the list.
    static func heading(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter(); f.locale = cn
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }
}
