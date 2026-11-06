import Foundation

/// A picture saved on this Mac, so the PDF no longer depends on the original site.
public struct LocalImage { public var source: String; public var file: URL; public var bytes: Int }

enum ImageKind {
    /// The file type by its first bytes; nil for anything that is not a picture (an HTML error page, say).
    static func ext(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(16))
        guard b.count >= 12 else { return nil }
        if b[0] == 0xff, b[1] == 0xd8 { return "jpg" }
        if b[0] == 0x89, b[1] == 0x50 { return "png" }
        if b[0] == 0x47, b[1] == 0x49 { return "gif" }
        if b[0] == 0x52, b[1] == 0x49, b[8] == 0x57, b[9] == 0x45 { return "webp" }
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            return brand.hasPrefix("avif") || brand.hasPrefix("avis") ? "avif" : "heic"
        }
        return nil
    }
}

/// Refuses redirects into the local network.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = newRequest.url, (try? URLGuard.checkResolved(u)) != nil { completionHandler(newRequest) } else { completionHandler(nil) }
    }
}

public enum ImageFetcher {
    static let maxBytes = 40 * 1024 * 1024
    private static let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    /// Downloads one image with the page as referer and the site's cookies (hotlink checks need both). Tries three times.
    public static func fetch(_ address: String, referer: String, userAgent: String, cookies: [HTTPCookie], to dir: URL, name: String) async -> Result<LocalImage, Error> {
        guard let url = URL(string: address) else { return .failure(CaptureError("图片地址无效")) }
        do { try await Task.detached { try URLGuard.checkResolved(url) }.value } catch { return .failure(error) }
        var last: Error = CaptureError("下载失败")
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600 * attempt)) }
            do {
                var req = URLRequest(url: url, timeoutInterval: 30)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue(referer, forHTTPHeaderField: "Referer")
                req.setValue("image/avif,image/webp,image/jpeg,image/png,*/*;q=0.8", forHTTPHeaderField: "Accept")
                let forURL = cookies.filter { c in
                    guard let host = url.host?.lowercased() else { return false }
                    let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return host == d || host.hasSuffix("." + d)
                }
                if let header = HTTPCookie.requestHeaderFields(with: forURL)["Cookie"] { req.setValue(header, forHTTPHeaderField: "Cookie") }
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { last = CaptureError("HTTP \(code)"); continue }
                guard data.count <= maxBytes else { return .failure(CaptureError("图片过大")) }
                guard let ext = ImageKind.ext(data) else { last = CaptureError("返回的不是图片"); continue }
                let file = dir.appendingPathComponent("\(name).\(ext)")
                try data.write(to: file)
                return .success(LocalImage(source: address, file: file, bytes: data.count))
            } catch { last = error }
        }
        return .failure(last)
    }
}
