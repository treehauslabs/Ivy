import Foundation
import Acorn

func testCID(for data: Data) -> String {
    ContentIdentifier(for: data).rawValue
}

