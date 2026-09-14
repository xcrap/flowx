import Testing
@testable import FXDesign

@Test func fileNavigatorSearchesParentFoldersAndNamesTogether() {
    let first = FXFileNavigatorItem(path: "Packages/FXCore/Tests/PolicyTests.swift", additions: 12)
    let other = FXFileNavigatorItem(path: "Packages/FXAgent/Tests/PolicyTests.swift")
    #expect(first.name == other.name)
    #expect(first.directory != other.directory)
    #expect(first.matches("  core policy  "))
    #expect(!other.matches("core policy"))
    #expect(first.matches(""))
    #expect(!first.matches("missing"))
    #expect(FXFileNavigatorItem(path: "README.md").directory == "Project root")
}
