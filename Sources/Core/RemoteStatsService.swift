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
            let snapshot = self.servers
            self.previous = [:]
            self.history = [:]
            self.samples = [:]
            self.inflight = []
            self.servers = []
            for server in snapshot {
                RemoteProbe.exitMaster(for: server)
            }
        }
    }

    func updateServers(_ servers: [RemoteServer]) {
        queue.async { [weak self] in
            guard let self else { return }
            let keep = Set(servers.map(\.id))
            self.servers = servers
            self.previous = self.previous.filter { keep.contains($0.key) }
            self.history = self.history.filter { keep.contains($0.key) }
            self.samples = self.samples.filter { keep.contains($0.key) }
            self.publish()
        }
    }

    private func poll(generation: Int) {
        let snapshot = servers
        for server in snapshot {
            guard isCurrent(generation) else { return }
            guard inflight.insert(server.id).inserted else { continue }
            let previous = previous[server.id]
            let history = history[server.id] ?? []
            let result = RemoteProbe.tick(server, previous: previous, history: history)
            inflight.remove(server.id)
            guard isCurrent(generation) else { return }
            if let raw = result.raw {
                self.previous[server.id] = raw
            }
            if result.sample.cpuReady {
                self.history[server.id] = result.sample.cpuHistory
            }
            samples[server.id] = result.sample
        }
        guard isCurrent(generation) else { return }
        publish()
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
