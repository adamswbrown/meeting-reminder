// Compile with: xcrun swiftc -parse-as-library probe-foundation-model.swift -o probe
// Synthetic local generation only; no external integrations or live meeting data.
import Foundation
import FoundationModels

@main struct FoundationModelProbe {
    static func main() async {
        guard #available(macOS 26.4, *) else {
            print("Requires macOS 26.4 or later for context and token inspection")
            return
        }
        let model = SystemLanguageModel.default
        print("availability=\(model.availability)")
        print("contextSize=\(model.contextSize)")
        guard case .available = model.availability else { return }
        do {
            let prompt = "Reply with exactly: READY"
            print("promptTokens=\(try await model.tokenCount(for: prompt))")
            let response = try await LanguageModelSession(model: model).respond(to: prompt)
            print("response=\(response.content)")
        } catch {
            print("error=\(error)")
        }
    }
}
