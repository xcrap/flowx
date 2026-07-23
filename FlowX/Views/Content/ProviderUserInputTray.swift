import SwiftUI
import AppKit
import FXAgent
import FXDesign

/// Provider-originated questions stay attached to the active turn instead of
/// being converted into ordinary chat messages. This preserves the provider's
/// native request/response contract for Codex and Claude Code.
struct ProviderUserInputTray: View {
    private struct AnswerFocus: Hashable {
        let requestID: UUID
        let questionID: String
    }

    let requests: [ProviderUserInputRequest]
    let onSubmit: (ProviderUserInputRequest, ProviderUserInputAnswers) -> Void
    let onCancel: (ProviderUserInputRequest) -> Void

    @State private var selectedAnswers: [UUID: ProviderUserInputAnswers] = [:]
    @State private var customAnswers: [UUID: [String: String]] = [:]
    @State private var touchedAnswers: [UUID: Set<String>] = [:]
    @State private var failedURLRequestID: UUID?
    @FocusState private var focusedAnswer: AnswerFocus?

    private var activeRequest: ProviderUserInputRequest? { requests.first }

    var body: some View {
        if let request = activeRequest {
            VStack(alignment: .leading, spacing: FXSpacing.lg) {
                header(for: request)

                if let message = request.message, !message.isEmpty {
                    Text(message)
                        .font(FXTypography.body)
                        .foregroundStyle(FXColors.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch request.presentation {
                case .form:
                    VStack(alignment: .leading, spacing: FXSpacing.lg) {
                        ForEach(request.questions) { question in
                            questionView(question, requestID: request.id)
                        }
                    }
                case .externalURL(let rawURL):
                    externalURLView(rawURL, requestID: request.id)
                case .decision:
                    decisionNotice
                }

                HStack(spacing: FXSpacing.sm) {
                    FXButton(
                        submitLabel(for: request),
                        icon: submitIcon(for: request),
                        style: submitStyle(for: request)
                    ) {
                        let answers = resolvedAnswers(for: request)
                        guard isComplete(request) else { return }
                        onSubmit(request, answers)
                        selectedAnswers[request.id] = nil
                        customAnswers[request.id] = nil
                        touchedAnswers[request.id] = nil
                    }
                    .disabled(!isComplete(request))

                    FXButton(cancelLabel(for: request), icon: cancelIcon(for: request), style: .ghost) {
                        onCancel(request)
                        selectedAnswers[request.id] = nil
                        customAnswers[request.id] = nil
                        touchedAnswers[request.id] = nil
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(FXSpacing.lg)
            .background(FXColors.accent.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.xl))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.xl)
                    .strokeBorder(FXColors.accent.opacity(0.22), lineWidth: 0.5)
            )
            .padding(.top, FXSpacing.md)
            .padding(.bottom, FXSpacing.sm)
            .frame(maxWidth: FXLayout.readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, FXSpacing.xxl)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Provider input required")
            .task(id: request.id) {
                seedDefaultAnswers(for: request)
            }
            .onChange(of: focusedAnswer) { _, focus in
                guard let focus else { return }
                var touched = touchedAnswers[focus.requestID] ?? []
                touched.insert(focus.questionID)
                touchedAnswers[focus.requestID] = touched
            }
        }
    }

    private func header(for request: ProviderUserInputRequest) -> some View {
        HStack(spacing: FXSpacing.sm) {
            Image(systemName: "questionmark.bubble.fill")
                .font(FXTypography.icon(.medium))
                .foregroundStyle(FXColors.accent)

            Text(request.title)
                .font(FXTypography.bodyMedium)
                .foregroundStyle(FXColors.fg)

            switch request.presentation {
            case .form:
                FXBadge(
                    request.questions.count == 1
                        ? "1 field"
                        : "\(request.questions.count) fields",
                    tone: .accent
                )
            case .externalURL:
                FXBadge("Secure link", tone: .accent)
            case .decision:
                FXBadge("Decision", tone: .warning)
            }

            if requests.count > 1 {
                FXBadge("+\(requests.count - 1) waiting", tone: .warning)
            }

            Spacer(minLength: 0)

        }
    }

    private func questionView(_ question: ProviderUserInputQuestion, requestID: UUID) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: FXSpacing.sm) {
                Text(question.header.uppercased())
                    .font(FXTypography.overline)
                    .foregroundStyle(FXColors.accent)

                if question.allowsMultiple {
                    Text("Choose any")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                }

                if !question.isRequired {
                    Text("Optional")
                        .font(FXTypography.caption)
                        .foregroundStyle(FXColors.fgTertiary)
                }
            }

            Text(question.question)
                .font(FXTypography.bodyMedium)
                .foregroundStyle(FXColors.fg)
                .fixedSize(horizontal: false, vertical: true)

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: FXSpacing.xs) {
                    ForEach(question.options, id: \.self) { option in
                        optionButton(option, for: question, requestID: requestID)
                    }
                }
            }

            if question.options.isEmpty || question.allowsOther {
                customAnswerField(for: question, requestID: requestID)
            }

            if let hint = constraintHint(for: question) {
                Text(hint)
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func optionButton(
        _ option: ProviderUserInputOption,
        for question: ProviderUserInputQuestion,
        requestID: UUID
    ) -> some View {
        let selected = selectedAnswers[requestID]?[question.id]?.contains(option.value) == true

        return Button {
            toggle(option.value, for: question, requestID: requestID)
        } label: {
            HStack(alignment: .top, spacing: FXSpacing.sm) {
                Image(systemName: selectionIcon(selected: selected, multiple: question.allowsMultiple))
                    .font(FXTypography.icon(.regular))
                    .foregroundStyle(selected ? FXColors.accent : FXColors.fgTertiary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: FXSpacing.xxxs) {
                    Text(option.label)
                        .font(FXTypography.bodyMedium)
                        .foregroundStyle(FXColors.fg)

                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(FXTypography.caption)
                            .foregroundStyle(FXColors.fgSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, FXSpacing.md)
            .padding(.vertical, FXSpacing.sm)
            .background(selected ? FXColors.accent.opacity(0.12) : FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.md)
                    .strokeBorder(selected ? FXColors.accent.opacity(0.38) : FXColors.borderSubtle, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.description)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func customAnswerField(for question: ProviderUserInputQuestion, requestID: UUID) -> some View {
        let binding = customAnswerBinding(for: question.id, requestID: requestID)
        let placeholder = answerPlaceholder(for: question)

        if question.isSecret {
            SecureField(question.options.isEmpty ? placeholder : "Other answer", text: binding)
                .textFieldStyle(.plain)
                .focused($focusedAnswer, equals: AnswerFocus(requestID: requestID, questionID: question.id))
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fg)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.sm)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.md)
                        .strokeBorder(FXColors.border, lineWidth: 0.5)
                )
                .accessibilityLabel(question.options.isEmpty ? placeholder : "Other answer")
        } else {
            TextField(question.options.isEmpty ? placeholder : "Other answer", text: binding)
                .textFieldStyle(.plain)
                .focused($focusedAnswer, equals: AnswerFocus(requestID: requestID, questionID: question.id))
                .font(FXTypography.body)
                .foregroundStyle(FXColors.fg)
                .padding(.horizontal, FXSpacing.md)
                .padding(.vertical, FXSpacing.sm)
                .background(FXColors.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
                .overlay(
                    RoundedRectangle(cornerRadius: FXRadii.md)
                        .strokeBorder(FXColors.border, lineWidth: 0.5)
                )
                .accessibilityLabel(question.options.isEmpty ? placeholder : "Other answer")
        }
    }

    private func selectionIcon(selected: Bool, multiple: Bool) -> String {
        if multiple { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(_ answer: String, for question: ProviderUserInputQuestion, requestID: UUID) {
        markTouched(question.id, requestID: requestID)
        var requestAnswers = selectedAnswers[requestID] ?? [:]
        if question.allowsMultiple {
            var answers = requestAnswers[question.id] ?? []
            if let index = answers.firstIndex(of: answer) {
                answers.remove(at: index)
            } else {
                answers.append(answer)
            }
            requestAnswers[question.id] = answers
        } else {
            requestAnswers[question.id] = [answer]
        }
        selectedAnswers[requestID] = requestAnswers

        var requestCustomAnswers = customAnswers[requestID] ?? [:]
        requestCustomAnswers[question.id] = ""
        customAnswers[requestID] = requestCustomAnswers
    }

    private func customAnswerBinding(for questionID: String, requestID: UUID) -> Binding<String> {
        Binding {
            customAnswers[requestID]?[questionID] ?? ""
        } set: { value in
            markTouched(questionID, requestID: requestID)
            var requestCustomAnswers = customAnswers[requestID] ?? [:]
            requestCustomAnswers[questionID] = value
            customAnswers[requestID] = requestCustomAnswers

            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var requestAnswers = selectedAnswers[requestID] ?? [:]
                requestAnswers[questionID] = []
                selectedAnswers[requestID] = requestAnswers
            }
        }
    }

    private func markTouched(_ questionID: String, requestID: UUID) {
        var touched = touchedAnswers[requestID] ?? []
        touched.insert(questionID)
        touchedAnswers[requestID] = touched
    }

    private func externalURLView(_ rawURL: String, requestID: UUID) -> some View {
        VStack(alignment: .leading, spacing: FXSpacing.sm) {
            HStack(alignment: .top, spacing: FXSpacing.sm) {
                Image(systemName: "lock.shield.fill")
                    .font(FXTypography.icon(.medium))
                    .foregroundStyle(FXColors.success)

                Text(rawURL)
                    .font(FXTypography.monoSmall)
                    .foregroundStyle(FXColors.fg)
                    .lineLimit(3)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }
            .padding(FXSpacing.md)
            .background(FXColors.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
            .overlay(
                RoundedRectangle(cornerRadius: FXRadii.md)
                    .strokeBorder(FXColors.border, lineWidth: 0.5)
            )

            FXButton("Open secure page", icon: "arrow.up.right.square", style: .secondary) {
                guard let url = safeHTTPSURL(rawURL), NSWorkspace.shared.open(url) else {
                    failedURLRequestID = requestID
                    return
                }
                failedURLRequestID = nil
            }

            if failedURLRequestID == requestID {
                Text("FlowX could not open this HTTPS page. Copy the address above into your browser, then choose Completed or Cancel.")
                    .font(FXTypography.caption)
                    .foregroundStyle(FXColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func safeHTTPSURL(_ rawURL: String) -> URL? {
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    private var decisionNotice: some View {
        HStack(alignment: .top, spacing: FXSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(FXTypography.icon(.small))
                .foregroundStyle(FXColors.warning)

            Text("FlowX cannot complete this request directly. Choose whether to decline it or cancel it without making a decision.")
                .font(FXTypography.caption)
                .foregroundStyle(FXColors.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(FXSpacing.md)
        .background(FXColors.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: FXRadii.md))
    }

    private func seedDefaultAnswers(for request: ProviderUserInputRequest) {
        guard selectedAnswers[request.id] == nil, customAnswers[request.id] == nil else { return }
        var selected: ProviderUserInputAnswers = [:]
        var custom: [String: String] = [:]
        var touched: Set<String> = []
        for question in request.questions where !question.defaultAnswers.isEmpty {
            touched.insert(question.id)
            if question.options.isEmpty {
                custom[question.id] = question.defaultAnswers[0]
            } else {
                selected[question.id] = question.defaultAnswers
            }
        }
        selectedAnswers[request.id] = selected
        customAnswers[request.id] = custom
        touchedAnswers[request.id] = touched
    }

    private func submitLabel(for request: ProviderUserInputRequest) -> String {
        switch request.presentation {
        case .form:
            return request.questions.isEmpty ? "Submit response" : "Submit answers"
        case .externalURL:
            return "Completed"
        case .decision(let actionLabel):
            return actionLabel
        }
    }

    private func submitIcon(for request: ProviderUserInputRequest) -> String {
        if case .decision = request.presentation { return "xmark.circle" }
        return "checkmark"
    }

    private func submitStyle(for request: ProviderUserInputRequest) -> FXButtonStyle {
        if case .decision = request.presentation { return .danger }
        return .primary
    }

    private func cancelLabel(for request: ProviderUserInputRequest) -> String {
        if case .decision = request.presentation { return "Cancel request" }
        return request.cancellationBehavior == .respondToProvider ? "Cancel" : "Stop turn"
    }

    private func cancelIcon(for request: ProviderUserInputRequest) -> String {
        request.cancellationBehavior == .respondToProvider ? "xmark" : "stop.fill"
    }

    private func answerPlaceholder(for question: ProviderUserInputQuestion) -> String {
        if question.allowsOther { return "Other answer" }
        switch question.valueFormat {
        case "email": return "name@example.com"
        case "uri": return "https://example.com"
        case "date": return "YYYY-MM-DD"
        case "date-time": return "ISO 8601 date and time"
        default: break
        }
        switch question.valueType {
        case .integer: return "Enter a whole number"
        case .number: return "Enter a number"
        case .boolean: return "Choose Yes or No"
        case .string: return "Type your answer"
        }
    }

    private func constraintHint(for question: ProviderUserInputQuestion) -> String? {
        var parts: [String] = []
        if question.isRequired { parts.append("Required") }
        switch question.valueType {
        case .integer: parts.append("Whole number")
        case .number: parts.append("Number")
        case .boolean: break
        case .string:
            if let format = question.valueFormat {
                parts.append(format == "date-time" ? "ISO 8601 date and time" : format.capitalized)
            }
        }
        if let minimum = question.minimumValue { parts.append("Minimum \(formattedNumber(minimum))") }
        if let maximum = question.maximumValue { parts.append("Maximum \(formattedNumber(maximum))") }
        if let minimum = question.minimumLength { parts.append("At least \(minimum) characters") }
        if let maximum = question.maximumLength { parts.append("At most \(maximum) characters") }
        if let minimum = question.minimumSelectionCount { parts.append("Choose at least \(minimum)") }
        if let maximum = question.maximumSelectionCount { parts.append("Choose at most \(maximum)") }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func formattedNumber(_ value: Double) -> String {
        if value.rounded() == value,
           value >= Double(Int64.min),
           value < Double(Int64.max) {
            return String(Int64(value))
        }
        return String(value)
    }

    private func resolvedAnswers(for request: ProviderUserInputRequest) -> ProviderUserInputAnswers {
        var result: ProviderUserInputAnswers = [:]
        let selected = selectedAnswers[request.id] ?? [:]
        let custom = customAnswers[request.id] ?? [:]
        let touched = touchedAnswers[request.id] ?? []

        for question in request.questions {
            if question.options.isEmpty, touched.contains(question.id) {
                let rawValue = custom[question.id] ?? ""
                let value = question.preservesWhitespace
                    ? rawValue
                    : rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty || question.allowsEmptyValue {
                    result[question.id] = [value]
                }
            } else if let answers = selected[question.id],
                      !answers.isEmpty || (touched.contains(question.id) && question.allowsEmptyValue) {
                result[question.id] = answers
            } else if question.isRequired, question.allowsMultiple, question.allowsEmptyValue {
                result[question.id] = []
            }
        }
        return result
    }

    private func isComplete(_ request: ProviderUserInputRequest) -> Bool {
        switch request.presentation {
        case .externalURL, .decision:
            return true
        case .form:
            break
        }
        let answers = resolvedAnswers(for: request)
        return request.questions.allSatisfy { question in
            guard let values = answers[question.id] else {
                return !question.isRequired
            }
            return valuesAreValid(values, for: question)
        }
    }

    private func valuesAreValid(_ values: [String], for question: ProviderUserInputQuestion) -> Bool {
        if !question.options.isEmpty {
            let allowed = Set(question.options.map(\.value))
            guard values.allSatisfy(allowed.contains), Set(values).count == values.count else { return false }
        }
        if question.allowsMultiple {
            if let minimum = question.minimumSelectionCount, values.count < minimum { return false }
            if let maximum = question.maximumSelectionCount, values.count > maximum { return false }
            return true
        }
        guard values.count == 1 else { return false }
        let value = values[0]
        switch question.valueType {
        case .string:
            if let minimum = question.minimumLength, value.count < minimum { return false }
            if let maximum = question.maximumLength, value.count > maximum { return false }
            return stringMatchesFormat(value, format: question.valueFormat)
        case .number:
            guard let number = Double(value), number.isFinite else { return false }
            return numberIsWithinBounds(number, question: question)
        case .integer:
            guard let integer = Int64(value) else { return false }
            return numberIsWithinBounds(Double(integer), question: question)
        case .boolean:
            return value == "true" || value == "false"
        }
    }

    private func numberIsWithinBounds(_ value: Double, question: ProviderUserInputQuestion) -> Bool {
        if let minimum = question.minimumValue, value < minimum { return false }
        if let maximum = question.maximumValue, value > maximum { return false }
        return true
    }

    private func stringMatchesFormat(_ value: String, format: String?) -> Bool {
        switch format {
        case "email":
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
        case "uri":
            return URLComponents(string: value)?.scheme?.isEmpty == false
        case "date":
            guard value.count == 10 else { return false }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: value) != nil
        case "date-time":
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) != nil
                || (try? Date.ISO8601FormatStyle().parse(value)) != nil
        case nil:
            return true
        default:
            return false
        }
    }
}
