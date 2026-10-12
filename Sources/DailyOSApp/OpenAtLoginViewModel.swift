import Combine
import Foundation

/// Registering DailyOS to open at login. The production adapter wraps
/// `SMAppService.mainApp` in the executable; tests use a fake.
public protocol LoginItem: AnyObject {
    /// What macOS currently has, including a change made in System Settings.
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Advanced's Open at Login toggle. On by default: the first launch with
/// this setting registers DailyOS once, and after that your choice, here
/// or in System Settings, stands. The Morning Brief needs the app running
/// to send, but this works on its own.
@MainActor
public final class OpenAtLoginViewModel: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var errorText: String?

    private let loginItem: any LoginItem

    public init(loginItem: any LoginItem, defaults: UserDefaults = .standard) {
        self.loginItem = loginItem
        self.isEnabled = loginItem.isEnabled
        let preference = OpenAtLoginPreference(defaults: defaults)
        if !preference.isDefaultApplied {
            preference.isDefaultApplied = true
            setEnabled(true)
        }
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            errorText = nil
        } catch {
            errorText = "macOS didn't accept the change: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Reads the real state again, for when Advanced opens.
    public func refresh() {
        isEnabled = loginItem.isEnabled
    }
}

/// Whether Open at Login's default has been applied, in `UserDefaults`.
/// macOS holds the login item itself; this only stops the default from
/// overriding your choice on a later launch.
struct OpenAtLoginPreference: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "openAtLoginDefaultApplied"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var isDefaultApplied: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
