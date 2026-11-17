import Foundation

/// Where an on-screen control the player moved, resized or turned off is kept, independent of the screen's resolution and
/// shape (`OscPlacement` of DELOS for Android). The default layout is never stored (DelosUI's `OscDefaultLayout` computes it
/// for every panel); a control the player changed is stored against its anchor, the side the default layout keeps it to: the
/// left cluster from the left edge, the right cluster from the right edge, Back, Guide, Start and the trackpad from the
/// horizontal centre; the upper controls from the top edge, the lower ones from the bottom edge. Offsets and sizes are in
/// layout units of the panel (a 72nd of its height, times the shrink of a panel squarer than 3:2), so a layout made on one
/// screen looks the same on any other and the middle stays centred.
public struct OscPlacement: Equatable, Sendable {
    public enum AnchorX: String, Sendable, CaseIterable {
        case left = "LEFT", center = "CENTER", right = "RIGHT"
    }

    public enum AnchorY: String, Sendable, CaseIterable {
        case top = "TOP", bottom = "BOTTOM"
    }

    public var anchorX: AnchorX
    public var anchorY: AnchorY
    /// From the anchor, in layout units: LEFT from the panel's left edge to the control's, CENTER from the panel's centre to
    /// the control's (negative to the left), RIGHT from the control's right edge to the panel's.
    public var x: Float
    /// TOP from the panel's top edge to the control's, BOTTOM from the control's bottom edge to the panel's, in layout units.
    public var y: Float
    public var width: Float
    public var height: Float
    public var enabled: Bool

    public init(anchorX: AnchorX, anchorY: AnchorY, x: Float, y: Float, width: Float, height: Float, enabled: Bool) {
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.enabled = enabled
    }
}

/// One stored layout as a JSON document (`OscLayoutStore` of DELOS for Android, the same format):
///
/// ```
/// {"version": 2, "id": "global", "elements": {"10": {"enabled": true, "anchorX": "CENTER", "anchorY": "BOTTOM",
///                                                    "x": -14.0, "y": 1.0, "width": 12.0, "height": 7.0}}}
/// ```
///
/// Only the controls the player changed are in it, by element id (`VirtualControllerElement.EID_*`). Android's version 1
/// (absolute pixels under each element id, converted once by `OscLayoutStore.migrate`) never existed on Apple, so there is
/// nothing to convert here.
public enum OscLayoutDocument {
    public static let version = 2
    /// The layout of every game; a layout of one game gets an id of its own.
    public static let global = "global"

    /// The placements of [json] by element id; empty when it is another version or unreadable (the default layout).
    public static func decode(_ json: String) -> [Int: OscPlacement] {
        guard let data = json.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (document["version"] as? NSNumber)?.intValue == version,
              let elements = document["elements"] as? [String: Any] else { return [:] }
        var placements: [Int: OscPlacement] = [:]
        for (key, value) in elements {
            guard let id = Int(key), let e = value as? [String: Any],
                  let anchorX = (e["anchorX"] as? String).flatMap(OscPlacement.AnchorX.init(rawValue:)),
                  let anchorY = (e["anchorY"] as? String).flatMap(OscPlacement.AnchorY.init(rawValue:)),
                  let x = (e["x"] as? NSNumber)?.floatValue, let y = (e["y"] as? NSNumber)?.floatValue,
                  let width = (e["width"] as? NSNumber)?.floatValue, let height = (e["height"] as? NSNumber)?.floatValue,
                  let enabled = e["enabled"] as? Bool
            else { return [:] }
            placements[id] = OscPlacement(anchorX: anchorX, anchorY: anchorY, x: x, y: y, width: width, height: height, enabled: enabled)
        }
        return placements
    }

    /// The document of layout [id] holding [placements].
    public static func encode(_ placements: [Int: OscPlacement], id: String) -> String {
        var elements: [String: Any] = [:]
        for (element, p) in placements {
            elements[String(element)] = [
                "enabled": p.enabled, "anchorX": p.anchorX.rawValue, "anchorY": p.anchorY.rawValue,
                "x": Double(p.x), "y": Double(p.y), "width": Double(p.width), "height": Double(p.height),
            ] as [String: Any]
        }
        let document: [String: Any] = ["version": version, "id": id, "elements": elements]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The stored on-screen control layouts of each profile (the `OSC` preferences of Android's `ProfileLayouts`): one JSON
/// document per layout under `layout.<id>` (``OscLayoutDocument``), in one `UserDefaults` value per profile (key
/// `osc.<profile id>`). A new profile starts with a copy of the current one's layouts, a deleted one's are removed with it.
public struct OnScreenControlsStore: Sendable {
    private let suiteName: String?

    /// - Parameter suiteName: a `UserDefaults` suite; nil is the app's standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String) -> String { "osc.\(profile)" }

    private static func layoutKey(_ layout: String) -> String { "layout.\(layout)" }

    private func documents(_ profile: String) -> [String: String] {
        defaults.dictionary(forKey: key(profile)) as? [String: String] ?? [:]
    }

    /// The changed controls of layout [layout] of [profile]; empty when there are none (or the document is unreadable).
    public func read(profile: String, layout: String = OscLayoutDocument.global) -> [Int: OscPlacement] {
        documents(profile)[Self.layoutKey(layout)].map(OscLayoutDocument.decode) ?? [:]
    }

    /// Stores [placements] as layout [layout] of [profile]; none removes the layout.
    public func write(_ placements: [Int: OscPlacement], profile: String, layout: String = OscLayoutDocument.global) {
        var all = documents(profile)
        all[Self.layoutKey(layout)] = placements.isEmpty ? nil : OscLayoutDocument.encode(placements, id: layout)
        if all.isEmpty { defaults.removeObject(forKey: key(profile)) } else { defaults.set(all, forKey: key(profile)) }
    }

    /// Every on-screen control of [profile] back to its default size and place (`option_reset_osc_preference`: Android clears
    /// the profile's `OSC` preferences).
    public func reset(profile: String) {
        defaults.removeObject(forKey: key(profile))
    }

    /// [into] gets a copy of [from]'s layouts (a new profile starts with the current one's, `ProfileLayouts.copy`).
    public func copy(from: String, into: String) {
        let all = documents(from)
        if all.isEmpty { defaults.removeObject(forKey: key(into)) } else { defaults.set(all, forKey: key(into)) }
    }

    /// Forgets a deleted profile's layouts.
    public func remove(profile: String) {
        defaults.removeObject(forKey: key(profile))
    }
}
