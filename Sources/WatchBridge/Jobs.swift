import Foundation
import WatchProtocol

/// Command jobs, keyed by the phone's requestId so a retried request never runs twice.
public final class JobBook: @unchecked Sendable {
    public static let capacity = 500
    private let lock = NSLock()
    private var jobs: [String: (job: Job, device: String)] = [:]   // by job id
    private var byRequest: [String: String] = [:]                  // device/requestId -> job id
    private var order: [String] = []
    public var onChange: ((Job, String) -> Void)?                 // job, device id

    public init() {}

    /// A new job for this request, or the existing one when the request was seen before.
    public func start(requestId: String, command: String, target: String?, deviceId: String,
                      now: Date = Date()) -> (Job, isNew: Bool) {
        lock.withLock {
            let key = deviceId + "/" + requestId
            if let id = byRequest[key], let j = jobs[id] { return (j.job, false) }
            let job = Job(id: "job-" + UUID().uuidString.prefix(12).lowercased(), requestId: requestId,
                          command: command, target: target, status: .accepted, at: now)
            jobs[job.id] = (job, deviceId)
            byRequest[key] = job.id
            order.append(job.id)
            while order.count > Self.capacity {
                let old = order.removeFirst()
                if let j = jobs.removeValue(forKey: old) { byRequest[j.device + "/" + j.job.requestId] = nil }
            }
            return (job, true)
        }
    }

    @discardableResult
    public func finish(_ id: String, _ status: JobStatus, reason: String? = nil) -> Job? {
        let r: (Job, String)? = lock.withLock {
            guard var j = jobs[id] else { return nil }
            j.job.status = status
            j.job.reason = reason
            jobs[id] = j
            return (j.job, j.device)
        }
        if let (job, device) = r { onChange?(job, device) }
        return r?.0
    }

    public func job(_ id: String) -> Job? { lock.withLock { jobs[id]?.job } }
}

/// One JSON line per remote command in remote-log.jsonl.
public final class AuditLog: @unchecked Sendable {
    struct Entry: Codable { var at: Date; var device: String; var command: String; var target: String?; var result: String; var reason: String? }
    private let url: URL
    private let lock = NSLock()
    public private(set) var last: (at: Date, text: String)?

    public init(url: URL) { self.url = url }

    public func append(device: String, command: String, target: String?, result: String, reason: String? = nil, now: Date = Date()) {
        let e = Entry(at: now, device: device, command: command, target: target, result: result, reason: reason)
        guard var line = try? WireCoder.encoder.encode(e) else { return }
        line.append(0x0A)
        lock.withLock {
            last = (now, "\(command) \(result) · \(device)")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
