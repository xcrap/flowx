import Foundation

extension BinarySpec {
    public static let claude = BinarySpec(
        id: "claude",
        displayName: "Claude Code",
        searchPaths: [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm/bin/claude",
            "\(NSHomeDirectory())/.nvm/versions/node/*/bin/claude",
        ],
        versionArgs: ["--version"],
        shellFallbackName: "claude",
        installHint: "npm install -g @anthropic-ai/claude-code"
    )

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
