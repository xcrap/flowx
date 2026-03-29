import Foundation

public enum AppEnvironment {
    public static var appSupportDirectoryName: String {
        #if DEBUG
        "FlowX-Dev"
        #else
        "FlowX"
        #endif
    }
}
