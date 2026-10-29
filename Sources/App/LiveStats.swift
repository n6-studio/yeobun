import Combine
import Foundation

/// Live Mac and remote samples. Separate from `AppModel` so a 1s tick
/// refreshes stat views only.
final class LiveStats: ObservableObject {
    @Published var sample = SystemSample()
    @Published var remoteSamples: [UUID: RemoteSample] = [:]
}
