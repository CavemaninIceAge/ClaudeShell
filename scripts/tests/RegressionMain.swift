import Foundation

@main
struct RegressionMain {
    @MainActor static func main() async {
        do {
            try await AuthFileRegression.run()
            try KeychainWriteRegression.run()
            try await AccountsRegression.run()
            try CodexPushRegression.run()
            try await AuthenticationSetupRegression.run()
            try await CodexRegression.run()
            try await CodexDesktopLifecycleRegression.run()
            try await NativeInteractionRegression.run()
            try WorkspaceNavigationRegression.run()
            try WorkspaceSessionRegression.run()
            try await WorkspaceToolsRegression.run()
            try await WorkspaceContentRegression.run()
            print("PASS — Claudex Shell isolated regression suite")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("FAIL — \(error)\n".utf8))
            exit(1)
        }
    }
}
