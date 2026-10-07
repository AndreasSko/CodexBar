# Claude subscription authority proof

This proof exercises `UsageStore.scheduleClaudeSubscriptionMetadataIfSupported` and its production worker, publication guards, snapshot update, saved-account cache update and widget persistence path. Only the HTTP transport and already accepted in-memory OAuth credential lookup are supplied by isolated fixtures through DEBUG-only task-local overrides. Account widgets are disabled. No real account, credential store or subscription is modified.

The test pauses the subscription HTTP response after initial ownership verification, changes authority while it is pending, and resumes the real worker. It compares the resulting active snapshot and saved-account cache with their values immediately before resuming, and counts widget persistence calls. The accepted case publishes dates and preserves a newer quota value.

| Scenario | Expected publication |
| --- | --- |
| Matching account, organization and credentials | Dates reach snapshot, saved-account cache and widget; newer quota preserved |
| Browser account changes before the final account check | All three publication sinks unchanged |
| OAuth organization reassigned while both browser memberships remain present | All three publication sinks unchanged |
| Accepted OAuth credential replaced while billing is pending | All three publication sinks unchanged |
| Selected manual cookie replaced while billing is pending | All three publication sinks unchanged |
| Selected saved account changed while billing is pending | All three publication sinks unchanged |
| Active snapshot changes to another account while billing is pending | All three publication sinks unchanged |
| Subsequent OAuth capture has the same history identifier | Prior owner and dates are not carried into the new capture |

## Authority-chain change

A usage-history identifier is no longer retained as evidence of current OAuth ownership. Each optional enrichment verifies the current OAuth profile and checks it again after billing requests. The browser account is also checked before and after billing. Local credential continuity, selected account, configuration revision, refresh generation and current snapshot checks still run before publication. Usage publication does not wait for these requests.

## Reproduce

Run the focused Swift tests matching `ClaudeSubscription(MetadataTests|PublicationProofTests)` with the repository test environment. The proof test is `Tests/CodexBarTests/ClaudeSubscriptionPublicationProofTests.swift`; parser and authenticated-fetch coverage is in `ClaudeSubscriptionMetadataTests.swift`.

All identifiers and credentials in these tests are fictional. Published proof output contains scenario names and sink outcomes only; it does not contain account identifiers, credentials or private endpoint paths. This is deterministic production-path behavior proof with controlled I/O, not a claim that real accounts were reassigned or real credentials were replaced during a live session. Live renewal verification is separate; a live cancelled-subscription response remains unverified.

## Observed result

The focused native-build run passed all 15 tests in two suites, including the seven parameterized scheduler cases. Sanitized output:

```text
AUTHORITY PROOF prior binding: not carried into next OAuth capture
AUTHORITY PROOF replacedManualCookie: snapshot/cache/widget unchanged; no publication
AUTHORITY PROOF accepted: snapshot/cache/widget published; newer quota preserved
AUTHORITY PROOF changedSelectedAccount: snapshot/cache/widget unchanged; no publication
AUTHORITY PROOF mismatchedAccount: snapshot/cache/widget unchanged; no publication
AUTHORITY PROOF changedActiveSnapshot: snapshot/cache/widget unchanged; no publication
AUTHORITY PROOF reassignedOrganization: snapshot/cache/widget unchanged; no publication
AUTHORITY PROOF replacedOAuthCredential: snapshot/cache/widget unchanged; no publication
```
