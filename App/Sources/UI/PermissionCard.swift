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
        case "Bash": return "Claude 想运行命令"
        case "Edit", "MultiEdit", "NotebookEdit": return "Claude 想修改文件"
        case "Write": return "Claude 想写入文件"
        case "Read": return "Claude 想读取文件"
        case "WebFetch": return "Claude 想访问网页"
        case "WebSearch": return "Claude 想搜索网页"
        case "AskUserQuestion": return "Claude 有问题问你"
        case "ExitPlanMode": return "Claude 想结束计划、开始动手"
        default: return "Claude 想使用 \(request.displayName)"
        }
    }

    private var summary: String? {
        let i = request.input
        switch request.toolName {
        case "Bash":
            let cmd = i["command"]?.string ?? ""
            if let d = i["description"]?.string, !d.isEmpty { return "\(cmd)\n# \(d)" }
            return cmd
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return i["file_path"]?.string ?? i["notebook_path"]?.string
        case "WebFetch": return i["url"]?.string
        case "WebSearch": return i["query"]?.string
        case "ExitPlanMode": return i["plan"]?.string
        default:
            let s = i.serialized(pretty: true)
            return s.count > 1200 ? String(s.prefix(1200)) + "\n…" : s
        }
    }
}

/// AskUserQuestion 的表单：每题一组可选项，加一个"其他"文本框。
private struct QuestionForm: View {
    let request: PermissionRequest
    let controller: ConversationController
    @State private var picks: [String: String] = [:]
    @State private var custom: [String: String] = [:]

    private var questions: [JSONValue] { request.input["questions"]?.array ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                let key = q["question"]?.string ?? ""
                VStack(alignment: .leading, spacing: 6) {
                    Text(key)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(Array((q["options"]?.array ?? []).enumerated()), id: \.offset) { _, opt in
                        let label = opt["label"]?.string ?? ""
                        Button {
                            picks[key] = label
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: picks[key] == label ? "largecircle.fill.circle" : "circle")
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
                    TextField("其他…", text: Binding(get: { custom[key] ?? "" }, set: { custom[key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                }
            }
            HStack {
                Button("跳过") { controller.respond(to: request, allow: false) }
                Spacer()
                Button("提交") {
                    var answers: [String: String] = [:]
                    for q in questions {
                        let key = q["question"]?.string ?? ""
                        let c = (custom[key] ?? "").trimmingCharacters(in: .whitespaces)
                        answers[key] = c.isEmpty ? (picks[key] ?? "") : c
                    }
                    controller.answerQuestion(request, answers: answers)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!questions.allSatisfy { q in
                    let key = q["question"]?.string ?? ""
                    return !(custom[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || picks[key] != nil
                })
            }
        }
    }
}
