import Foundation

@main
struct RegressionMain {
    @MainActor static func main() async {
        do {
            try await AuthFileRegression.run()
            try await AccountsRegression.run()
            try await CodexRegression.run()
            try WorkspaceNavigationRegression.run()
            try await WorkspaceContentRegression.run()
            print("PASS — Claudex Shell isolated regression suite")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("FAIL — \(error)\n".utf8))
            exit(1)
        }
    }
}
