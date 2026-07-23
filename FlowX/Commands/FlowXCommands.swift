import AppKit
import SwiftUI
import FXAgent
import FXDesign
import FXTerminal

struct FlowXCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Project…") {
                appState.openAddProjectPanel()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("New Thread") {
                guard let project = appState.activeProject, hasUsableProvider else { return }
                _ = appState.addAgent(to: project, title: "New Thread")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(appState.activeProject == nil || !hasUsableProvider)
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                withAnimation(FXAnimation.panel) {
                    appState.commandPaletteVisible = true
                }
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Toggle Sidebar") {
                appState.sidebarVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Toggle Git Panel") {
                appState.toggleGitPanel()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!appState.activeProjectCanShowGitPanel)

            Button("Toggle Terminal") {
                appState.activeAgent?.workspace.terminalVisible.toggle()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState.activeAgent == nil)

            Button("Toggle Browser Preview") {
                appState.toggleBrowserPreview()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(appState.activeAgent == nil)

            Button(appState.settingsVisible ? "Hide Settings" : "Show Settings") {
                appState.settingsVisible.toggle()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Conversation") {
            Button(primaryPromptActionTitle) {
                guard let agent = activeAgent else { return }
                appState.sendPrompt(
                    for: agent,
                    followUpMode: defaultFollowUpMode
                )
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!hasSendableDraft || activeAgentIsSubmittingSteer)

            Button(alternatePromptActionTitle) {
                guard let agent = activeAgent else { return }
                appState.sendPrompt(
                    for: agent,
                    followUpMode: defaultFollowUpMode.opposite
                )
            }
            .keyboardShortcut(.return, modifiers: .control)
            .disabled(!hasSendableDraft || activeAgentIsSubmittingSteer)

            Button("Attach Images…") {
                guard let agent = activeAgent else { return }
                appState.attachFiles(to: agent)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(activeAgent == nil || !activeModelSupportsVision || activeAgentIsSubmittingSteer)

            if activeAgent?.isStreaming == true {
                Divider()

                Button("Stop Current Run") {
                    guard let agent = activeAgent else { return }
                    appState.cancelPrompt(for: agent)
                }
                .keyboardShortcut(".", modifiers: .command)
            }

            Divider()

            Button("Reset Conversation") {
                guard let agent = activeAgent else { return }
                appState.resetConversation(for: agent)
            }
            .disabled(activeAgent == nil || activeAgent?.isStreaming == true)
        }

        CommandMenu("Terminal") {
            Button("Add Terminal Split") {
                activeAgent?.addTerminalPane()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(activeAgent == nil || (activeAgent?.terminalPaneCount ?? 3) >= 3)

            Button("Clear All Terminals") {
                for session in activeAgent?.visibleTerminalSessions ?? [] where session.isRunning {
                    session.clearScreen()
                }
            }
            .disabled(runningTerminalSessions.isEmpty)

            Button("Interrupt Running Terminals") {
                for session in runningTerminalSessions {
                    session.interrupt()
                }
            }
            .disabled(runningTerminalSessions.isEmpty)

            Button("Restart Exited Terminals") {
                for session in activeAgent?.visibleTerminalSessions ?? [] where !session.isRunning && session.lastExitCode != nil {
                    session.restart()
                }
            }
            .disabled(exitedTerminalSessions.isEmpty)
        }

        CommandMenu("Threads") {
            if let project = appState.activeProject, !project.agents.isEmpty {
                ForEach(Array(project.agents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                    Button("Open \(agent.title)") {
                        appState.activateAgent(agent.id, in: project.id)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            } else {
                Button("No Threads Available") {}
                    .disabled(true)
            }

            if let activeAgent,
               let project = appState.activeProject,
               !appState.threadLifecycleActions(for: activeAgent).isEmpty {
                Divider()
                ForEach(appState.threadLifecycleActions(for: activeAgent), id: \.self) { action in
                    Button(
                        action.title,
                        role: action.isDestructive ? .destructive : nil
                    ) {
                        appState.requestThreadLifecycleAction(action, for: activeAgent)
                    }
                    .disabled(appState.threadLifecycleBlockedReason(for: activeAgent, in: project) != nil)
                }
            }

            if appState.projects.contains(where: {
                !$0.archivedNativeThreadBindings.isEmpty
            }) {
                Button("Archived Tasks…") {
                    appState.settingsTab = .archivedTasks
                    appState.settingsVisible = true
                }
            }
        }

        CommandGroup(after: .saveItem) {
            if let project = appState.activeProject {
                Button("Show Project in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.project.rootURL])
                }

                Button("Copy Project Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(project.project.rootPath, forType: .string)
                }
            }
        }
    }

    private var activeAgent: AgentInfo? {
        appState.activeAgent
    }

    private var defaultFollowUpMode: PromptFollowUpMode {
        appState.preferences.defaultFollowUpMode
    }

    private var primaryPromptActionTitle: String {
        guard activeAgent?.isStreaming == true else { return "Send Prompt" }
        return defaultFollowUpMode == .steer ? "Steer Active Run" : "Queue Follow-Up"
    }

    private var alternatePromptActionTitle: String {
        guard activeAgent?.isStreaming == true else { return "Send Prompt (Alternate Shortcut)" }
        return defaultFollowUpMode.opposite == .steer ? "Steer Active Run" : "Queue Follow-Up"
    }

    private var hasSendableDraft: Bool {
        guard let activeAgent else { return false }
        return !activeAgent.conversationState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !activeAgent.conversationState.pendingAttachments.isEmpty
    }

    private var activeAgentIsSubmittingSteer: Bool {
        guard let activeAgent else { return false }
        return appState.isSubmittingSteer(for: activeAgent.id)
    }

    private var activeModelSupportsVision: Bool {
        guard let activeAgent,
              let provider = appState.providerRegistry.provider(for: activeAgent.providerID) else {
            return false
        }
        guard let selectedModelID = activeAgent.explicitModelID ?? activeAgent.nativeModelID,
              let model = provider.availableModels.first(where: { $0.id == selectedModelID }) else {
            return provider.capabilities.supportedAttachments.contains(.image)
        }
        return model.supportsVision
    }

    private var runningTerminalSessions: [TerminalSession] {
        activeAgent?.visibleTerminalSessions.filter(\.isRunning) ?? []
    }

    private var exitedTerminalSessions: [TerminalSession] {
        activeAgent?.visibleTerminalSessions.filter { !$0.isRunning && $0.lastExitCode != nil } ?? []
    }

    private var hasUsableProvider: Bool {
        appState.providerRegistry.allProviders.contains { provider in
            appState.runtimeHealth[provider.id]?.isUsable == true && !provider.availableModels.isEmpty
        }
    }
}
