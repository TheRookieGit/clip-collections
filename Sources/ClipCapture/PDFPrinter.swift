import AppKit
import WebKit

/// WKWebView.createPDF gives one endless page, so real pagination goes through a print operation that saves to a file.
@MainActor
enum PDFPrinter {
    static let a4 = NSSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 40

    static func print(_ view: WKWebView, to file: URL, in window: NSWindow) async throws {
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = NSPrintInfo()
        info.paperSize = a4
        info.orientation = .portrait
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        let op = view.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(origin: .zero, size: a4)
        let ok: Bool = await withCheckedContinuation { c in
            let done = PrintDone(c)
            op.runModal(for: window, delegate: done, didRun: #selector(PrintDone.finished(_:success:context:)),
                        contextInfo: Unmanaged.passRetained(done).toOpaque())
        }
        guard ok, FileManager.default.fileExists(atPath: file.path) else { throw CaptureError("PDF 生成失败") }
    }
}

private final class PrintDone: NSObject {
    private let c: CheckedContinuation<Bool, Never>
    init(_ c: CheckedContinuation<Bool, Never>) { self.c = c }
    @objc func finished(_ op: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        if let context { Unmanaged<PrintDone>.fromOpaque(context).release() }
        c.resume(returning: success)
    }
}
