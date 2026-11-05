import Foundation

/// The copy on the desktop. Written once and never overwritten or removed: `Clip.exportedAt` records it, and deleting
/// an item anywhere leaves the file alone.
public enum Exporter {
    /// A safe "<date> <title>" name. A title comes from the web, so anything that could change the folder goes.
    public static func baseName(title: String, date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        var clean = String(title.unicodeScalars.map { s -> Character in
            if s.value < 32 || s.value == 127 || "/\\:*?\"<>|".unicodeScalars.contains(s) || CharacterSet.newlines.contains(s) { return " " }
            if (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value) || s.value == 0x200B { return " " }
            return Character(s)
        })
        clean = clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let f = clean.first, f == "." || f == " " { clean.removeFirst() }
        while let l = clean.last, l == "." || l == " " { clean.removeLast() }
        if clean.isEmpty { clean = "未命名" }
        // A file name holds 255 bytes; leaves room for the date, a number and .pdf.
        while clean.utf8.count > 200 { clean.removeLast() }
        return "\(df.string(from: date)) \(clean)"
    }

    /// Copies without ever replacing: a taken name gets a number.
    public static func export(pdf: URL, title: String, date: Date, to folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = baseName(title: title, date: date)
        for n in 1...9999 {
            let name = n == 1 ? "\(base).pdf" : "\(base) (\(n)).pdf"
            let target = folder.appendingPathComponent(name)
            guard !name.contains("/"), target.lastPathComponent == name else { throw CaptureError("文件名无效") }
            do { try fm.copyItem(at: pdf, to: target); return target }
            catch let e as CocoaError where e.code == .fileWriteFileExists { continue }
        }
        throw CaptureError("同名文件太多")
    }
}
