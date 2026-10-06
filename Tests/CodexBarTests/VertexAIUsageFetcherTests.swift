import Foundation
import Testing
@testable import CodexBarCore

struct VertexAIUsageFetcherTests {
    @Test
    func `usage without limit name matches the regional named limit`() throws {
        let response = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.fixture("issue-2958-usage-without-limit-name"),
            limitData: Self.fixture("issue-2958-regional-and-global-limits"))

        #expect(response.requestsUsedPercent == 1)
    }

    @Test
    func `existing exact limit name match remains authoritative`() throws {
        let response = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.fixture("exact-named-usage"),
            limitData: Self.fixture("exact-named-limits"))

        #expect(response.requestsUsedPercent == 25)
    }

    @Test
    func `unnamed usage does not guess between limits in the same region`() throws {
        #expect(throws: VertexAIFetchError.self) {
            try VertexAIUsageFetcher.parseQuotaUsage(
                usageData: Self.fixture("issue-2958-usage-without-limit-name"),
                limitData: Self.fixture("ambiguous-regional-limits"))
        }
    }

    @Test
    func `repeated page token stops before requesting the same page again`() async throws {
        let log = RequestLog()
        let transport = ProviderHTTPTransportHandler { request in
            await log.append(request)
            return try Self.ok(request, #"{"timeSeries":[],"nextPageToken":"page-2"}"#)
        }

        await #expect(throws: VertexAIFetchError.self) {
            _ = try await VertexAIUsageFetcher.fetchUsage(
                accessToken: "token",
                projectId: "project",
                transport: transport)
        }
        #expect(await log.pageTokens == [nil, "page-2"])
    }

    @Test
    func `finite pages still aggregate across page tokens`() async throws {
        let log = RequestLog()
        let transport = ProviderHTTPTransportHandler { request in
            await log.append(request)
            let query = request.url?.query(percentEncoded: false) ?? ""
            if query.contains("quota/limit") {
                return try Self.ok(request, Self.fixture("exact-named-limits"))
            }
            if Self.pageToken(request) == nil {
                return try Self.ok(request, #"{"timeSeries":[],"nextPageToken":"page-2"}"#)
            }
            return try Self.ok(request, Self.fixture("exact-named-usage"))
        }

        let response = try await VertexAIUsageFetcher.fetchUsage(
            accessToken: "token",
            projectId: "project",
            transport: transport)

        #expect(response.requestsUsedPercent == 25)
        #expect(await log.pageTokens == [nil, "page-2", nil])
    }

    private actor RequestLog {
        private(set) var pageTokens: [String?] = []

        func append(_ request: URLRequest) {
            self.pageTokens.append(VertexAIUsageFetcherTests.pageToken(request))
        }
    }

    private static func pageToken(_ request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pageToken" }?.value
    }

    private static func ok(_ request: URLRequest, _ body: String) throws -> (Data, URLResponse) {
        try Self.ok(request, Data(body.utf8))
    }

    private static func ok(_ request: URLRequest, _ body: Data) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (body, response)
    }

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Providers/VertexAI")))
    }
}
