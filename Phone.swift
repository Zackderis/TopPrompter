import Foundation
import Network
import CoreImage
import AppKit
import Security

/// Serves the iPhone display page over your local network and answers its polls.
/// The phone shows the script; the Mac stays in charge (scrolling, Talk/Follow listening).
final class PhoneServer {
    struct State { var c: Double; var playing: Bool; var mode: Int; var hearing: Bool; var dim: Int; var word: NSRange? = nil }

    static let port: UInt16 = 8765
    /// Secret part of the link (only the QR code / copied link has it). Without it every request gets 404,
    /// so other people on the same Wi-Fi can't read the script or control playback.
    static var key: String = {
        if let k = UserDefaults.standard.string(forKey: "phoneKey"), k.count >= 20 { return k }
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        let k = String(bytes.map { chars[Int($0) % chars.count] })
        UserDefaults.standard.set(k, forKey: "phoneKey")
        return k
    }()
    var stateProvider: (() -> State)?
    var scriptProvider: (() -> (version: Int, text: String))?
    var onCommand: ((String) -> Void)?
    private var listener: NWListener?
    private(set) var running = false
    var onError: ((String) -> Void)?

    private lazy var page: Data = {
        guard let url = Bundle.main.url(forResource: "phone", withExtension: "html"),
              let d = try? Data(contentsOf: url) else { return Data("phone.html missing from the app bundle".utf8) }
        return d
    }()

    func start() {
        guard listener == nil else { return }
        _ = Self.key                                   // make sure the secret exists before serving
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st {
                    self?.running = false
                    self?.onError?("The iPhone link couldn't start: \(e.localizedDescription)")
                }
            }
            l.start(queue: .main)
            listener = l
            running = true
        } catch {
            onError?("The iPhone link couldn't start: \(error.localizedDescription)")
        }
    }

    func stop() { listener?.cancel(); listener = nil; running = false }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let first = req.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = first.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let comps = URLComponents(string: target)
            let full = comps?.path ?? "/"
            let prefix = "/" + Self.key + "/"
            guard full.hasPrefix(prefix) else {
                self.send(conn, Data("Not found".utf8), type: "text/plain", status: "404 Not Found"); return
            }
            let path = "/" + full.dropFirst(prefix.count)
            switch path {
            case "/", "/index.html":
                self.send(conn, self.page, type: "text/html; charset=utf-8")
            case "/state":
                let s = self.stateProvider?() ?? State(c: 0, playing: false, mode: 0, hearing: false, dim: 0)
                let v = self.scriptProvider?().version ?? 0
                let json = String(format: "{\"v\":%d,\"c\":%.2f,\"p\":%@,\"m\":%d,\"h\":%@,\"d\":%d,\"w\":%d,\"wl\":%d}",
                                  v, s.c, s.playing ? "true" : "false", s.mode, s.hearing ? "true" : "false", s.dim,
                                  s.word?.location ?? -1, s.word?.length ?? 0)
                self.send(conn, Data(json.utf8), type: "application/json")
            case "/script":
                let sc = self.scriptProvider?() ?? (version: 0, text: "")
                let obj: [String: Any] = ["v": sc.version, "text": sc.text]
                self.send(conn, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8), type: "application/json")
            case "/cmd":
                if let c = comps?.queryItems?.first(where: { $0.name == "c" })?.value { self.onCommand?(c) }
                self.send(conn, Data("{}".utf8), type: "application/json")
            default:
                self.send(conn, Data("Not found".utf8), type: "text/plain", status: "404 Not Found")
            }
        }
    }

    private func send(_ conn: NWConnection, _ body: Data, type: String, status: String = "200 OK") {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: address + QR

    /// The Mac's local IPv4 addresses (Wi-Fi or wired), best first.
    static func localIPs() -> [String] {
        var out: [(String, String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }      // skip VPN/bridge interfaces
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }          // self-assigned, not reachable
            out.append((name, ip))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func url() -> String? {
        guard let ip = localIPs().first else { return nil }
        return "http://\(ip):\(port)/\(key)/"
    }

    static func qrImage(_ text: String, size: CGFloat = 220) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage else { return nil }
        let scale = size / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
