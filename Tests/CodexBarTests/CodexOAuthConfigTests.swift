import Foundation
import Testing
@testable import CodexBarCore

@Suite(CodexCredentialFixtures())
struct CodexOAuthConfigTests {
    @Test(arguments: ["#", "# ", "  # ", "\t# "])
    func `ignores commented chat GPT base URL`(prefix: String) {
        let config = "\(prefix)chatgpt_base_url = \"http://127.0.0.1:8788/backend-api/\"\n"
        let home = CodexCredentialFixtures.root.appendingPathComponent("commented-base-url-\(UUID().uuidString)")
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(
            env: ["CODEX_HOME": home.path],
            configContents: config)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    @Test
    func `uses active chat GPT base URL after commented override`() {
        let config = """
        # chatgpt_base_url = "http://127.0.0.1:8788/backend-api/"
        chatgpt_base_url = "https://proxy.example/backend-api/" # Active override
        """
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://proxy.example/backend-api/wham/usage")
    }
}
