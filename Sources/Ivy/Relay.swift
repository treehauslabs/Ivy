import Foundation

actor RelayService {
    struct Circuit: Sendable {
        let peerA: String
        let peerB: String
        let created: ContinuousClock.Instant
        var bytesRelayed: Int = 0

        static let maxDuration: Duration = .seconds(120)
        static let maxBytes = 128 * 1024

        var isExpired: Bool {
            created.duration(to: .now) > Self.maxDuration || bytesRelayed >= Self.maxBytes
        }
    }

    private var circuits: [String: Circuit] = [:]
    private let maxCircuitsPerPeer = 4
    private let maxTotalCircuits = 128

    private func circuitKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a):\(b)" : "\(b):\(a)"
    }

    func createCircuit(initiator: String, target: String) -> Bool {
        pruneExpired()
        let key = circuitKey(initiator, target)
        guard circuits[key] == nil else { return false }
        guard circuits.count < maxTotalCircuits else { return false }

        let peerCircuits = circuits.values.filter { $0.peerA == initiator || $0.peerB == initiator }.count
        guard peerCircuits < maxCircuitsPerPeer else { return false }

        circuits[key] = Circuit(peerA: initiator, peerB: target, created: .now)
        return true
    }

    func relay(from src: String, to dst: String, bytes: Int) -> Bool {
        let key = circuitKey(src, dst)
        guard var circuit = circuits[key] else { return false }
        if circuit.isExpired {
            circuits.removeValue(forKey: key)
            return false
        }
        circuit.bytesRelayed += bytes
        circuits[key] = circuit
        return true
    }

    func hasCircuit(between a: String, and b: String) -> Bool {
        let key = circuitKey(a, b)
        guard let circuit = circuits[key] else { return false }
        return !circuit.isExpired
    }

    func removeCircuit(between a: String, and b: String) {
        circuits.removeValue(forKey: circuitKey(a, b))
    }

    func removeAllCircuits(forPeer peerKey: String) {
        circuits = circuits.filter { $0.value.peerA != peerKey && $0.value.peerB != peerKey }
    }

    private func pruneExpired() {
        circuits = circuits.filter { !$0.value.isExpired }
    }
}
