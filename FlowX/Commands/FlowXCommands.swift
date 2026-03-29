import SwiftUI
import FXDesign

struct FlowXCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                withAnimation(FXAnimation.panel) {
                    appState.sidebarVisible.toggle()
                }
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Toggle Right Panel") {
                withAnimation(FXAnimation.panel) {
                    appState.rightPanelVisible.toggle()
                }
            }
            .keyboardShortcut("\\", modifiers: .command)

            Button("Toggle Terminal") {
                withAnimation(FXAnimation.panel) {
                    appState.activeAgent?.workspace.terminalVisible.toggle()
                }
            }
            .keyboardShortcut("`", modifiers: .command)
        }

        CommandMenu("Agents") {
            if let project = appState.activeProject, !project.agents.isEmpty {
                ForEach(Array(project.agents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                    Button("Select \(agent.title)") {
                        appState.activeProjectID = project.id
                        appState.activeAgentID = agent.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            } else {
                Button("No Agents Available") {}
                    .disabled(true)
            }
        }
    }
}
