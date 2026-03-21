import Foundation
import Crypto
import Tally

public struct ChainDestination: Sendable, Hashable {
    public let chainDirectory: String
    public let destinationHash: Data

    public init(chainDirectory: String) {
        self.chainDirectory = chainDirectory
        self.destinationHash = Router.truncatedHash(Data("lattice.chain.\(chainDirectory)".utf8))
    }

    public init(chainDirectory: String, specCID: String) {
        self.chainDirectory = chainDirectory
        let material = Data("lattice.chain.\(chainDirectory).\(specCID)".utf8)
        self.destinationHash = Router.truncatedHash(material)
    }

    public static func nexus() -> ChainDestination {
        ChainDestination(chainDirectory: "Nexus")
    }
}
