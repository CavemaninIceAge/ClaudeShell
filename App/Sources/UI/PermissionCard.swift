import SwiftUI

/// 权限审批卡：Claude 想运行命令 / 改文件时出现在输入卡上方；AskUserQuestion 也走这里。
struct PermissionCard: View {
    let request: PermissionRequest
    let controller: ConversationController
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(request.toolName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            if request.toolName == "AskUserQuestion" {
                QuestionForm(request: request, controller: controller)
            } else if request.toolName == "MCP input" {
                ElicitationForm(request: request, controller: controller)
            } else {
                if let summary {
                    Text(summary)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(expanded ? nil : 4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
                        .onTapGesture { expanded.toggle() }
                }
                if request.id.hasPrefix("codex-rpc:"), request.toolName == "Bash" {
                    ForEach(Array(CodexEvents.approvalDecisions(request.input).enumerated()), id: \.offset) { _, decision in
                        VStack(alignment: .leading, spacing: 4) {
                            if decision.object != nil {
                                Text(decision.serialized(pretty: true))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Button(CodexEvents.decisionLabel(decision)) { controller.respondCodexDecision(to: request, decision: decision) }
                                .disabled(!CodexEvents.isKnownDecision(decision))
                        }
                    }
                } else {
                  HStack(spacing: 8) {
                    Button("拒绝") { controller.respond(to: request, allow: false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if request.suggestions?.array?.isEmpty == false {
                        Button("本会话总是允许") { controller.respond(to: request, allow: true, always: true) }
                    }
                    Button("允许") { controller.respond(to: request, allow: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PrimaryButtonStyle())
                  }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private var icon: String {
        switch request.toolName {
        case "Bash": return "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil.line"
        case "Read": return "doc.text"
        case "WebFetch", "WebSearch": return "globe"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    private var headline: String {
        switch request.toolName {
        case "Bash": return "\(controller.engine.displayName) 想运行命令"
        case "Edit", "MultiEdit", "NotebookEdit": return "\(controller.engine.displayName) 想修改文件"
        case "Write": return "\(controller.engine.displayName) 想写入文件"
        case "Read": return "\(controller.engine.displayName) 想读取文件"
        case "WebFetch": return "\(controller.engine.displayName) 想访问网页"
        case "WebSearch": return "\(controller.engine.displayName) 想搜索网页"
        case "AskUserQuestion": return "\(controller.engine.displayName) 有问题问你"
        case "ExitPlanMode": return "\(controller.engine.displayName) 想结束计划、开始动手"
        default: return "\(controller.engine.displayName) 想使用 \(request.displayName)"
        }
    }

    private var summary: String? {
        let i = request.input
        switch request.toolName {
        case "Bash":
            let cmd = i["command"]?.string ?? ""
            if request.id.hasPrefix("codex-rpc:") {
                var lines = [cmd]
                for key in ["kind", "cwd", "reason", "networkApprovalContext", "additionalPermissions"] {
                    if let value = i[key], !value.isNull { lines.append("\(key): \(value.string ?? value.serialized(pretty: true))") }
                }
                return lines.filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if let d = i["description"]?.string, !d.isEmpty { return "\(cmd)\n# \(d)" }
            return cmd
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return i["file_path"]?.string ?? i["notebook_path"]?.string ?? i.serialized(pretty: true)
        case "WebFetch": return i["url"]?.string
        case "WebSearch": return i["query"]?.string
        case "ExitPlanMode": return i["plan"]?.string
        default:
            let s = i.serialized(pretty: true)
            return s.count > 1200 ? String(s.prefix(1200)) + "\n…" : s
        }
    }
}

/// Provider flags control single/multiple selection and whether free text is permitted.
private struct QuestionForm: View {
    let request: PermissionRequest
    let controller: ConversationController
    @State private var picks: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]

    private var questions: [InteractionQuestion] { InteractionQuestion.parse(request) }

    private func answer(_ question: InteractionQuestion) -> [String] {
        let text = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return question.allowsCustom && !text.isEmpty ? [text] : (picks[question.id] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions) { q in
                let key = q.id
                VStack(alignment: .leading, spacing: 6) {
                    if let header = q.header, !header.isEmpty {
                        Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(q.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(Array(q.options.enumerated()), id: \.offset) { _, opt in
                        let label = opt["label"]?.string ?? ""
                        Button {
                            if q.multiple {
                                var values = picks[key] ?? []
                                if values.contains(label) { values.removeAll { $0 == label } } else { values.append(label) }
                                picks[key] = values
                            } else { picks[key] = [label] }
                            custom[key] = nil
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: q.multiple ? ((picks[key] ?? []).contains(label) ? "checkmark.square.fill" : "square") : ((picks[key] ?? []).contains(label) ? "largecircle.fill.circle" : "circle"))
                                    .font(.system(size: 12))
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label).font(.system(size: 12.5, weight: .medium))
                                    if let d = opt["description"]?.string, !d.isEmpty {
                                        Text(d).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if q.allowsCustom {
                        let binding = Binding(get: { custom[key] ?? "" }, set: { custom[key] = $0 })
                        Group {
                            if q.secret { SecureField("请输入回答", text: binding) }
                            else { TextField(q.options.isEmpty ? "请输入回答" : "其他…", text: binding) }
                        }
                        .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
                    }
                }
            }
            HStack {
                Button("跳过") { controller.respond(to: request, allow: false) }
                Spacer()
                Button("提交") {
                    var selections: [String: [String]] = [:]
                    for q in questions { selections[q.wireKey] = answer(q) }
                    controller.answerQuestion(request, selections: selections)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(questions.isEmpty || !questions.allSatisfy { !answer($0).isEmpty })
            }
        }
    }
}

private struct ElicitationForm: View {
    let request: PermissionRequest
    let controller: ConversationController
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.input["message"]?.string ?? "MCP 服务需要补充信息")
            if let fields = CodexElicitation.fields(request.input) {
                ForEach(fields, id: \.0) { key, schema in
                    VStack(alignment: .leading, spacing: 4) {
                        let required = request.input["requestedSchema"]?["required"]?.array?.contains(.string(key)) == true
                        Text((schema["title"]?.string ?? key) + (required ? " *" : ""))
                            .font(.system(size: 12, weight: .medium))
                        if let description = schema["description"]?.string { Text(description).font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                        let binding = Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
                        if let options = schema["enum"]?.array?.compactMap(\.string) {
                            Picker("选择", selection: binding) {
                                Text("请选择").tag("")
                                ForEach(options, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        } else if schema["type"]?.string == "boolean" {
                            Picker("选择", selection: binding) {
                                Text("请选择").tag(""); Text("是").tag("true"); Text("否").tag("false")
                            }.labelsHidden()
                        } else { TextField("请输入", text: binding).textFieldStyle(.roundedBorder) }
                    }
                }
                HStack {
                    Button("拒绝") { controller.respond(to: request, allow: false) }
                    Spacer()
                    Button("提交") { controller.answerElicitation(request, values: values) }
                        .disabled(CodexElicitation.result(params: request.input, values: values) == nil)
                }
            } else {
                if let url = request.input["url"]?.string { Text(url).textSelection(.enabled) }
                Text("此请求需要外部验证或暂不支持的表单格式。可拒绝后继续对话。")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Button("拒绝请求") { controller.respond(to: request, allow: false) }
            }
        }
    }
}
