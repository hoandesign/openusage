import Foundation

enum MuseAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Muse not detected. Run muse login or set META_API_KEY."
        }
    }
}

struct MuseAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// Resolved path to the Muse credential file (also honors MUSE_AUTH_PATH).
    var credentialPath: String {
        if let override = environment.value(for: "MUSE_AUTH_PATH")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        if let xdg = environment.value(for: "XDG_CONFIG_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("muse/auth.json")
        }
        return homeDirectory().appendingPathComponent(".config/muse/auth.json").path
    }

    var sessionsRoot: String {
        // Honors XDG_DATA_HOME if set, else ~/.local/share/muse
        if let xdg = environment.value(for: "XDG_DATA_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("muse/sessions")
        }
        return homeDirectory().appendingPathComponent(".local/share/muse/sessions").path
    }

    /// Whether any tracked credential exists on this machine.
    func hasCredentialFootprint() -> Bool {
        // Env token counts as login
        if let token = environment.value(for: "META_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return true
        }
        if files.exists(credentialPath) { return true }
        // Local session history is itself evidence the CLI has been used
        if files.exists(sessionsRoot) { return true }
        return false
    }
}


