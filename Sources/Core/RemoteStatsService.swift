import Foundation

/// Polls saved SSH remotes while the panel is open.
final class RemoteStatsService {
    var onUpdate: (([UUID: RemoteSample]) -> Void)?

    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 2
    private var servers: [RemoteServer] = []
    private var previous: [UUID: RemoteRaw] = [:]
    private var history: [UUID: [Double]] = [:]
    private var samples: [UUID: RemoteSample] = [:]
    private var inflight = Set<UUID>()
    private let queue = DispatchQueue(label: "studio.n6.yeobun.remote-stats", qos: .utility)
    private let pollQueue = DispatchQueue(label: "studio.n6.yeobun.remote-poll", qos: .utility, attributes: .concurrent)
    private let stateLock = NSLock()
    private var generation = 0

    func start(servers: [RemoteServer], interval: TimeInterval = 2.0) {
        let id = nextGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            self.servers = servers
            let keep = Set(servers.map(\.id))
            self.previous = self.previous.filter { keep.contains($0.key) }
            self.history = self.history.filter { keep.contains($0.key) }
            self.samples = self.samples.filter { keep.contains($0.key) }
            if self.timer != nil, abs(self.interval - interval) < 0.01 {
                self.publish()
                return
            }
            self.interval = interval
            self.stopTimer()
            self.publish()
            guard self.isCurrent(id), !servers.isEmpty else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.05, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self, self.isCurrent(id) else { return }
                self.poll(generation: id)
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        _ = nextGeneration()
        queue.async { [weak self] in
            guard let self else { return }
            self.stopTimer()
            self.previous = [:]
            self.history = [:]
            self.samples = [:]
            self.inflight = []
            self.servers = []
            // Leave SSH masters to ControlPersist. Closing the panel should
            // not pay a handshake the next time it opens.
        }
    }

    func updateServers(_ servers: [RemoteServer]) {
        queue.async { [weak self] in
            guard let self else { return }
            let keep = Set(servers.map(\.id))
            let removed = self.servers.filter { !keep.contains($0.id) }
            self.servers = servers
            self.previous = self.previous.filter { keep.contains($0.key) }
            self.history = self.history.filter { keep.contains($0.key) }
            self.samples = self.samples.filter { keep.contains($0.key) }
            self.inflight = self.inflight.filter { keep.contains($0) }
            self.publish()
            if !removed.isEmpty {
                self.pollQueue.async {
                    for server in removed {
                        RemoteProbe.exitMaster(for: server)
                    }
                }
            }
        }
    }

    /// Each host runs on its own queue so a slow SSH session cannot stall the others.
    private func poll(generation: Int) {
        let pending = servers.filter { inflight.insert($0.id).inserted }
        guard !pending.isEmpty else { return }
        let group = DispatchGroup()
        for server in pending {
            let previous = previous[server.id]
            let history = history[server.id] ?? []
            group.enter()
            pollQueue.async { [weak self] in
                let result = RemoteProbe.tick(server, previous: previous, history: history)
                guard let self else {
                    group.leave()
                    return
                }
                self.queue.async {
                    defer { group.leave() }
                    self.inflight.remove(server.id)
                    guard self.isCurrent(generation) else { return }
                    if let raw = result.raw {
                        self.previous[server.id] = raw
                    }
                    if result.sample.cpuReady {
                        self.history[server.id] = result.sample.cpuHistory
                    }
                    self.samples[server.id] = result.sample
                }
            }
        }
        group.notify(queue: queue) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.publish()
        }
    }

    private func publish() {
        var next = samples
        for server in servers where next[server.id] == nil {
            next[server.id] = .connecting()
        }
        onUpdate?(next)
    }

    private func nextGeneration() -> Int {
        stateLock.lock()
        generation += 1
        let value = generation
        stateLock.unlock()
        return value
    }

    private func isCurrent(_ id: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == id
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
