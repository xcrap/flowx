import Testing
@testable import FXCore

@Test func userAttachmentEnvelopePresentsOnlyTheRequest() {
    let source = """
    # Files mentioned by the user:

    ## first.png: /private/tmp/first.png

    ## second.png: /private/tmp/second.png

    ## My request for Codex:
    Make the attachment presentation compact.
    """

    let presentation = TranscriptPresentationParser.userMessage(source)

    #expect(presentation.visibleText == "Make the attachment presentation compact.")
    #expect(presentation.attachmentFilenames == ["first.png", "second.png"])
}

@Test func ordinaryUserMessageIsPreservedExactly() {
    let source = "Please keep this ordinary message unchanged.\nIt has two lines."

    #expect(
        TranscriptPresentationParser.userMessage(source)
            == UserMessagePresentation(visibleText: source)
    )
}

@Test func assistantDirectivesBecomeStructuredPresentationData() {
    let source = """
    Changes are published.

    ::git-stage{cwd="/Users/example/project"}
    ::git-commit{cwd="/Users/example/project"}
    ::git-push{cwd="/Users/example/project" branch="main"}
    """

    let presentation = TranscriptPresentationParser.assistantMessage(source)

    #expect(presentation.visibleText == "Changes are published.")
    #expect(presentation.directives.map(\.name) == ["git-stage", "git-commit", "git-push"])
    #expect(presentation.directives.last?["branch"] == "main")
    #expect(presentation.directives.last?["cwd"] == "/Users/example/project")
}

@Test func directiveSyntaxInsideProseRemainsVisible() {
    let source = "Explain ::git-push{cwd=\"/tmp/project\" branch=\"main\"} without running it."

    #expect(
        TranscriptPresentationParser.assistantMessage(source)
            == AssistantMessagePresentation(visibleText: source)
    )
}
