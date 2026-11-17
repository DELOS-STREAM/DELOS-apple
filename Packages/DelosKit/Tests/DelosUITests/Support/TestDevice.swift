#if os(macOS)
import SwiftUI
import Testing

struct TestDevice: Sendable, CustomTestStringConvertible {
    let name: String
    let size: CGSize
    let safe: EdgeInsets
    var testDescription: String { name }

    static let all = [
        TestDevice(name: "iPad landscape", size: CGSize(width: 1376, height: 1032), safe: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
        TestDevice(name: "iPad portrait", size: CGSize(width: 1032, height: 1376), safe: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
        TestDevice(name: "iPhone landscape", size: CGSize(width: 932, height: 430), safe: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)),
        TestDevice(name: "iPhone portrait", size: CGSize(width: 430, height: 932), safe: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)),
        TestDevice(name: "Apple TV", size: CGSize(width: 1920, height: 1080), safe: EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)),
    ]
}

#endif
