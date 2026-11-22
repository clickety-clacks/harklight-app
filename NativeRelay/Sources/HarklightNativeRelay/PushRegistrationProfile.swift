public enum PushRegistrationProfile: String, Equatable, Sendable {
    case sandbox = "harklight-sandbox"
    case production = "harklight-production"

    public enum BuildConfiguration: Equatable, Sendable {
        case debug
        case release
    }

    public static func forBuildConfiguration(_ configuration: BuildConfiguration) -> Self {
        switch configuration {
        case .debug: return .sandbox
        case .release: return .production
        }
    }

    public static var current: Self {
        // The development receiver script builds Debug; the app archive action builds Release.
        #if DEBUG
        return forBuildConfiguration(.debug)
        #else
        return forBuildConfiguration(.release)
        #endif
    }
}
