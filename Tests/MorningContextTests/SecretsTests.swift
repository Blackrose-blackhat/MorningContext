import Testing
@testable import MorningContext

@Suite("Secret redaction")
struct SecretsTests {
    @Test("Known token formats are redacted", arguments: [
        "sk-ant-api03-" + String(repeating: "a", count: 40),
        "sk-proj-" + String(repeating: "B", count: 30),
        "ghp_" + String(repeating: "x", count: 36),
        "github_pat_" + String(repeating: "1", count: 40),
        "AKIA" + "ABCDEFGHIJKLMNOP",
        "AIza" + String(repeating: "Z", count: 35),
        "xoxb-1234567890-abcdef",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    ])
    func redactsToken(_ token: String) {
        let out = Secrets.redact("before \(token) after")
        #expect(!out.contains(token))
        #expect(out.contains("[REDACTED]"))
        #expect(out.hasPrefix("before "))
        #expect(out.hasSuffix(" after"))
    }

    @Test func redactsPrivateKeyBlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\nabc\n-----END RSA PRIVATE KEY-----"
        #expect(Secrets.redact("key:\n\(pem)\ndone") == "key:\n[REDACTED]\ndone")
    }

    @Test("Keeps the key name, drops the value", arguments: [
        ("api_key=supersecretvalue", "api_key=[REDACTED]"),
        ("password: \"hunter2hunter2\"", "password: \"[REDACTED]\""),
        ("TOKEN = abcdefgh12345", "TOKEN = [REDACTED]"),
    ])
    func keepsAssignmentName(_ input: String, _ expected: String) {
        #expect(Secrets.redact(input) == expected)
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "Fixed the token refresh bug in auth.swift; password reset flow still TODO. See PR #42."
        #expect(Secrets.redact(text) == text)
    }
}
