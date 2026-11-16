import CDelosCommon

/// Facts the core gives about itself.
public enum CoreInfo {
    /// The extra query parameters the launch request must carry for this core (`LiGetLaunchUrlQueryParameters`).
    public static var launchQueryParameters: String { String(cString: LiGetLaunchUrlQueryParameters()) }
}
