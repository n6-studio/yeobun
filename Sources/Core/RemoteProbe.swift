import Darwin
import Foundation

enum RemoteProbeError: LocalizedError {
    case timeout
    case auth(String)
    case offline(String)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Timed out"
        case .auth(let message), .offline(let message), .unsupported(let message), .failed(let message):
            return message
        }
    }

    var status: RemoteLinkStatus {
        switch self {
        case .auth: .auth
        case .unsupported: .unsupported
        case .timeout, .offline: .offline
        case .failed: .offline
        }
    }
}

enum RemoteProbe {
    private static let ssh = "/usr/bin/ssh"
    private static let connectTimeout = 3
    private static let runTimeout: TimeInterval = 8

    static func sampleOnce(_ server: RemoteServer) throws -> RemoteSample {
        let first = try collect(server)
        if first.os != "Linux" {
            throw RemoteProbeError.unsupported("Needs a Linux host")
        }
        Thread.sleep(forTimeInterval: 0.3)
        let second = try collect(server)
        return makeSample(current: second, previous: first, history: [])
    }

    static func tick(
        _ server: RemoteServer,
        previous: RemoteRaw?,
        history: [Double]
    ) -> (sample: RemoteSample, raw: RemoteRaw?) {
        do {
            let raw = try collect(server)
            if raw.os != "Linux" {
                return (
                    .failed(.unsupported, notice: "Needs a Linux host"),
                    raw
                )
            }
            return (makeSample(current: raw, previous: previous, history: history), raw)
        } catch let error as RemoteProbeError {
            return (.failed(error.status, notice: error.errorDescription), previous)
        } catch {
            return (.failed(.offline, notice: error.localizedDescription), previous)
        }
    }

    static func exitMaster(for server: RemoteServer) {
        let arguments = controlOptions(for: server) + ["-O", "exit", server.destination]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ssh)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private static func collect(_ server: RemoteServer) throws -> RemoteRaw {
        try FileManager.default.createDirectory(
            at: YeobunPaths.sshControlDirectory,
            withIntermediateDirectories: true
        )
        let arguments = probeOptions(for: server) + [server.destination, remoteCommand]
        let result = try run(arguments, timeout: runTimeout)
        if result.status != 0 {
            throw classify(stderr: result.stderr, status: result.status)
        }
        let raw = RemoteRaw.parse(result.stdout)
        if raw.os.isEmpty {
            throw RemoteProbeError.failed("The host returned no stats.")
        }
        return raw
    }

    private static func probeOptions(for server: RemoteServer) -> [String] {
        var options = baseOptions(for: server)
        options += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-o", "LogLevel=ERROR"]
        return options
    }

    private static func controlOptions(for server: RemoteServer) -> [String] {
        baseOptions(for: server) + ["-o", "LogLevel=ERROR"]
    }

    private static func baseOptions(for server: RemoteServer) -> [String] {
        var options = [
            "-o", "ControlMaster=auto",
            "-o", YeobunPaths.sshControlPathOption,
            "-o", "ControlPersist=60"
        ]
        if let user = server.user, !user.isEmpty {
            options += ["-l", user]
        }
        if let port = server.port {
            options += ["-p", "\(port)"]
        }
        if let identity = server.identityPath, !identity.isEmpty {
            let path = (identity as NSString).expandingTildeInPath
            options += ["-i", path, "-o", "IdentitiesOnly=yes"]
        }
        return options
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) throws -> (stdout: String, stderr: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ssh)
        task.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw RemoteProbeError.failed("Could not start ssh.")
        }

        let group = DispatchGroup()
        group.enter()
        task.terminationHandler = { _ in group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            usleep(150_000)
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
            throw RemoteProbeError.timeout
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, task.terminationStatus)
    }

    private static func classify(stderr: String, status _: Int32) -> RemoteProbeError {
        let text = stderr.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.contains("permission denied")
            || lowered.contains("authentication")
            || lowered.contains("no more authentication methods") {
            return .auth("Needs SSH key")
        }
        if lowered.contains("host key verification failed") {
            return .offline("Host key unknown. SSH in once from Terminal")
        }
        if lowered.contains("could not resolve")
            || lowered.contains("name or service not known")
            || lowered.contains("nodename nor servname") {
            return .offline("Could not resolve host")
        }
        if lowered.contains("connection refused") {
            return .offline("Connection refused")
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return .timeout
        }
        if lowered.contains("unix_listener")
            || lowered.contains("too long for unix domain socket")
            || lowered.contains("controlpath extra arguments") {
            return .failed("Could not connect")
        }
        if text.isEmpty {
            return .offline("Offline")
        }
        return .failed(String(text.prefix(80)))
    }

    private static func makeSample(
        current: RemoteRaw,
        previous: RemoteRaw?,
        history: [Double]
    ) -> RemoteSample {
        var sample = RemoteSample()
        sample.status = .ok
        sample.hostname = current.hostname.isEmpty ? nil : current.hostname
        sample.load1 = current.load1
        sample.load5 = current.load5
        sample.load15 = current.load15
        sample.uptimeSeconds = current.uptime
        sample.ramTotal = current.memTotal
        sample.ramUsed = current.memUsed
        sample.swapTotal = current.swapTotal
        sample.swapUsed = current.swapUsed
        sample.diskTotal = current.diskTotal
        sample.diskUsed = current.diskUsed
        sample.topProcesses = current.processes
        sample.powerWatts = powerWatts(current: current, previous: previous)
        if sample.powerWatts == nil, !current.powerHint.isEmpty {
            sample.powerHint = current.powerHint
        }

        if let previous, previous.cpuTotal > 0, current.cpuTotal > previous.cpuTotal {
            let idleDelta = current.cpuIdle &- previous.cpuIdle
            let totalDelta = current.cpuTotal &- previous.cpuTotal
            if totalDelta > 0 {
                let busy = 1.0 - Double(idleDelta) / Double(totalDelta)
                sample.cpuFraction = min(max(busy, 0), 1)
                sample.cpuReady = true
            }
        }

        var nextHistory = history
        if sample.cpuReady {
            nextHistory.append(sample.cpuFraction)
            if nextHistory.count > 30 {
                nextHistory.removeFirst(nextHistory.count - 30)
            }
        }
        sample.cpuHistory = nextHistory
        return sample
    }

    private static func powerWatts(current: RemoteRaw, previous: RemoteRaw?) -> Double? {
        if let previous {
            let interval = current.uptime - previous.uptime
            let maxEnergy = current.energyMaxUj > 0 ? current.energyMaxUj : previous.energyMaxUj
            if let watts = PowerStats.watts(
                energyUj: current.energyUj,
                previousEnergyUj: previous.energyUj,
                maxEnergyUj: maxEnergy,
                interval: interval
            ) {
                return watts
            }
        }
        return PowerStats.watts(microwatts: current.powerMicrowatts)
    }

    /// POSIX sh, no single quotes, so it can sit inside `exec /bin/sh -c '…'`.
    private static let remoteCommand = "exec /bin/sh -c '" + probeScript + "'"

    private static let probeScript = #"""
os=$(uname -s)
printf "v=1\n"
printf "os=%s\n" "$os"
host=$(uname -n 2>/dev/null || printf "")
host=$(printf "%s" "$host" | tr -d "\n\r")
printf "host=%s\n" "$host"
if [ "$os" != Linux ]
then
  exit 0
fi
if [ -r /proc/loadavg ]
then
  read load1 load5 load15 rest < /proc/loadavg
  printf "load1=%s\n" "$load1"
  printf "load5=%s\n" "$load5"
  printf "load15=%s\n" "$load15"
fi
if [ -r /proc/stat ]
then
  read cpu user nice system idle iowait irq softirq steal extra < /proc/stat
  : ${iowait:=0}
  : ${irq:=0}
  : ${softirq:=0}
  : ${steal:=0}
  idle_all=$((idle + iowait))
  total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  printf "cpu_idle=%s\n" "$idle_all"
  printf "cpu_total=%s\n" "$total"
fi
if [ -r /proc/meminfo ]
then
  mem_total=0
  mem_avail=0
  mem_free=0
  buffers=0
  cached=0
  swap_total=0
  swap_free=0
  while IFS= read -r line
  do
    set -- $line
    key=$1
    val=$2
    case $key in
      MemTotal:) mem_total=$val ;;
      MemAvailable:) mem_avail=$val ;;
      MemFree:) mem_free=$val ;;
      Buffers:) buffers=$val ;;
      Cached:) cached=$val ;;
      SwapTotal:) swap_total=$val ;;
      SwapFree:) swap_free=$val ;;
    esac
  done < /proc/meminfo
  if [ "$mem_avail" = 0 ]
  then
    mem_avail=$((mem_free + buffers + cached))
  fi
  printf "mem_total_kb=%s\n" "$mem_total"
  printf "mem_avail_kb=%s\n" "$mem_avail"
  printf "swap_total_kb=%s\n" "$swap_total"
  printf "swap_used_kb=%s\n" "$((swap_total - swap_free))"
fi
if [ -r /proc/uptime ]
then
  read uptime idle < /proc/uptime
  printf "uptime=%s\n" "$uptime"
fi
energy_uj=0
energy_max_uj=0
energy_ok=0
if [ -d /sys/class/powercap ]
then
  for path in /sys/class/powercap/intel-rapl:*
  do
    [ -r "$path/name" ] || continue
    [ -r "$path/energy_uj" ] || continue
    read name < "$path/name"
    case "$name" in
      package-*)
        read uj < "$path/energy_uj"
        case "$uj" in
          ""|*[!0-9]*) continue ;;
        esac
        energy_uj=$((energy_uj + uj))
        energy_ok=1
        if [ -r "$path/max_energy_range_uj" ]
        then
          read mx < "$path/max_energy_range_uj"
          case "$mx" in
            ""|*[!0-9]*) ;;
            *) energy_max_uj=$((energy_max_uj + mx)) ;;
          esac
        fi
        ;;
    esac
  done
fi
if [ "$energy_ok" = 1 ]
then
  printf "energy_uj=%s\n" "$energy_uj"
  printf "energy_max_uj=%s\n" "$energy_max_uj"
fi
power_uw=0
if [ -d /sys/class/power_supply ]
then
  for ps in /sys/class/power_supply/*
  do
    [ "$power_uw" = 0 ] || break
    if [ -r "$ps/power_now" ]
    then
      read p < "$ps/power_now"
      case "$p" in
        -*) p=${p#-} ;;
      esac
      case "$p" in
        ""|*[!0-9]*) ;;
        *)
          if [ "$p" -gt 0 ]
          then
            power_uw=$p
          fi
          ;;
      esac
    elif [ -r "$ps/current_now" ] && [ -r "$ps/voltage_now" ]
    then
      read cur < "$ps/current_now"
      read volt < "$ps/voltage_now"
      case "$cur" in
        -*) cur=${cur#-} ;;
      esac
      case "$volt" in
        -*) volt=${volt#-} ;;
      esac
      case "$cur" in
        ""|*[!0-9]*) cur=0 ;;
      esac
      case "$volt" in
        ""|*[!0-9]*) volt=0 ;;
      esac
      if [ "$cur" -gt 0 ] && [ "$volt" -gt 0 ]
      then
        power_uw=$((cur * volt / 1000000))
      fi
    fi
  done
fi
if [ "$power_uw" = 0 ] && [ -d /sys/class/hwmon ]
then
  for hw in /sys/class/hwmon/hwmon*
  do
    [ "$power_uw" = 0 ] || break
    [ -r "$hw/name" ] || continue
    [ -r "$hw/power1_input" ] || continue
    read n < "$hw/name"
    case "$n" in
      power_meter|acpi_power_meter)
        read p < "$hw/power1_input"
        case "$p" in
          ""|*[!0-9]*) ;;
          *)
            if [ "$p" -gt 0 ]
            then
              power_uw=$p
            fi
            ;;
        esac
        ;;
    esac
  done
fi
if [ "$power_uw" != 0 ]
then
  printf "power_uw=%s\n" "$power_uw"
fi
if [ "$energy_ok" != 1 ] && [ "$power_uw" = 0 ]
then
  hint=none
  for path in /sys/class/powercap/intel-rapl:*
  do
    [ -e "$path/energy_uj" ] || continue
    if [ ! -r "$path/energy_uj" ]
    then
      hint=chmod
      break
    fi
  done
  printf "power_hint=%s\n" "$hint"
fi
df -Pk / 2>/dev/null | {
  read header
  read fs blocks used avail cap mount
  if [ -n "$blocks" ]
  then
    printf "disk_total_kb=%s\n" "$blocks"
    printf "disk_used_kb=%s\n" "$used"
  fi
}
ps -eo pid=,pcpu=,rss=,comm= --sort=-pcpu 2>/dev/null | {
  n=0
  while IFS= read -r line
  do
    [ "$n" -ge 3 ] && break
    set -- $line
    [ $# -lt 4 ] && continue
    pid=$1
    pcpu=$2
    rss=$3
    shift 3
    comm=$*
    printf "proc=%s,%s,%s,%s\n" "$pid" "$pcpu" "$rss" "$comm"
    n=$((n+1))
  done
}
"""#
}

struct RemoteRaw {
    var os = ""
    var hostname = ""
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var cpuIdle: UInt64 = 0
    var cpuTotal: UInt64 = 0
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var uptime: TimeInterval = 0
    var diskTotal: UInt64 = 0
    var diskUsed: UInt64 = 0
    var energyUj: UInt64 = 0
    var energyMaxUj: UInt64 = 0
    var powerMicrowatts: UInt64 = 0
    var powerHint = ""
    var processes: [ProcessUsage] = []

    static func parse(_ text: String) -> RemoteRaw {
        var raw = RemoteRaw()
        var processes: [ProcessUsage] = []
        var memAvailable: UInt64 = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            if line.hasPrefix("proc=") {
                if let process = parseProcess(String(line.dropFirst(5))) {
                    processes.append(process)
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "os": raw.os = value
            case "host": raw.hostname = value
            case "load1": raw.load1 = Double(value)
            case "load5": raw.load5 = Double(value)
            case "load15": raw.load15 = Double(value)
            case "cpu_idle": raw.cpuIdle = UInt64(value) ?? 0
            case "cpu_total": raw.cpuTotal = UInt64(value) ?? 0
            case "mem_total_kb": raw.memTotal = kilobytes(value)
            case "mem_avail_kb": memAvailable = kilobytes(value)
            case "swap_total_kb": raw.swapTotal = kilobytes(value)
            case "swap_used_kb": raw.swapUsed = kilobytes(value)
            case "uptime": raw.uptime = TimeInterval(value) ?? 0
            case "disk_total_kb": raw.diskTotal = kilobytes(value)
            case "disk_used_kb": raw.diskUsed = kilobytes(value)
            case "energy_uj": raw.energyUj = UInt64(value) ?? 0
            case "energy_max_uj": raw.energyMaxUj = UInt64(value) ?? 0
            case "power_uw": raw.powerMicrowatts = UInt64(value) ?? 0
            case "power_hint": raw.powerHint = value
            default: break
            }
        }
        if raw.memTotal >= memAvailable {
            raw.memUsed = raw.memTotal - memAvailable
        }
        raw.processes = processes
        return raw
    }

    private static func kilobytes(_ value: String) -> UInt64 {
        guard let kb = UInt64(value.split(separator: ".").first.map(String.init) ?? value) else { return 0 }
        return kb &* 1024
    }

    private static func parseProcess(_ line: String) -> ProcessUsage? {
        let parts = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let pid = Int32(parts[0]) else { return nil }
        let cpu = Double(parts[1]) ?? 0
        let ram = kilobytes(String(parts[2]))
        let name = String(parts[3])
        guard !name.isEmpty else { return nil }
        return ProcessUsage(pid: pid, name: name, cpuPercent: cpu, ramBytes: ram)
    }
}
