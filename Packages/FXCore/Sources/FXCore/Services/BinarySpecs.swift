import Foundation

extension BinarySpec {
    public static let codex = BinarySpec(
        id: "codex",
        displayName: "Codex",
        searchPaths: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "\(NSHomeDirectory())/.nvm/versions/node/*/bin/codex",
        ],
        versionArgs: ["--version"],
        shellFallbackName: "codex",
        installHint: "npm install -g @openai/codex"
    )
}
