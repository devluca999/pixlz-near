import Foundation
import Network

/// Finds a Mosaico: `_pixlz._tcp` with TXT `kind=mosaico` (SPEC §10.3), or a fixed host and port.
enum Discovery {
    static let serviceType = "_pixlz._tcp"
    static let defaultPort: UInt16 = 47860

    /// Calls back once with the first Mosaico found, or nil after `timeout`.
    static func findMosaico(timeout: TimeInterval, queue: DispatchQueue, found: @escaping (NWEndpoint?) -> Void) {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)
        var done = false
        func finish(_ e: NWEndpoint?) {
            guard !done else { return }
            done = true
            browser.cancel()
            found(e)
        }
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                if case .bonjour(let txt) = r.metadata, txt["kind"] == "mosaico" {
                    log("found \(r.endpoint)")
                    finish(r.endpoint)
                    return
                }
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
}
