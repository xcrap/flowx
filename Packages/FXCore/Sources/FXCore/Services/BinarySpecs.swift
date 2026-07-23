import Foundation

extension BinarySpec {
    public static let claude = BinarySpec(
        id: "claude",
        displayName: "Claude Code",
        searchPaths: [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
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
            // Reuse the signed runtime already used by the desktop agent so
            // FlowX sees the same native tasks and avoids a quarantined CLI
            // download taking precedence when both installations exist.
            "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
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
