import SwiftUI

@main
struct SelfnoteApp: App {
    var body: some Scene {
        WindowGroup {
            NotesHomeView()
                .tint(.accentColor)
        }
    }
}
