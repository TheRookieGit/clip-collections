import CoreGraphics
import Foundation
import ImageIO

/// This app's own Supabase Edge Function (supabase/functions/api), which also serves the web page.
public struct CloudAPI {
    public var url: String
    public var passcode: String
    public init(url: String, passcode: String) { self.url = url; self.passcode = passcode }
    public var configured: Bool { !url.isEmpty && !passcode.isEmpty }

    @discardableResult
    public func call(_ body: [String: Any], timeout: TimeInterval = 120) async throws -> [String: Any] {
        guard let endpoint = URL(string: url), configured else { throw CaptureError("请先在设置里填写云端口令") }
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue(passcode, forHTTPHeaderField: "x-passcode")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CaptureError("云端：\(j["error"] as? String ?? "出错了")") }
        return j
    }

    /// A screenshot sized for the web page: at most 1800 wide, as JPEG, under the upload limit.
    public static func webJPEG(_ file: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        for (side, q) in [(1800.0, 0.86), (1500, 0.8), (1200, 0.72), (1000, 0.65)] {
            let s = min(1, side / Double(cg.width), 12000 / Double(cg.height))
            let w = max(1, Int(Double(cg.width) * s)), h = max(1, Int(Double(cg.height) * s))
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            c.interpolationQuality = .high
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let img = c.makeImage(), let d = ClaudeAPI.jpeg(img, quality: q), d.count * 4 / 3 < 7_500_000 { return d }
        }
        return nil
    }
}
