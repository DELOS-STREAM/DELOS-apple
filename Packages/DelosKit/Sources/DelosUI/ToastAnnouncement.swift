import Accessibility
import Foundation

struct ToastAnnouncement {
    let text: String
    let urgent: Bool

    init(_ toast: Toast) {
        text = Self.text(word: toast.kind.word, message: toast.text, action: toast.action?.label)
        urgent = toast.kind == .error
    }

    static func text(word: String, message: String, action: String?) -> String {
        action.map { L("toast_description_action", word, message, $0) } ?? L("toast_description", word, message)
    }

    var speech: AttributedString {
        var value = AttributedString(text)
        value.accessibilitySpeechAnnouncementPriority = urgent ? .high : .low
        return value
    }

    @MainActor func post() {
        AccessibilityNotification.Announcement(speech).post()
    }
}
