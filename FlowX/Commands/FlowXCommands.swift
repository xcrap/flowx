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
    }
}
