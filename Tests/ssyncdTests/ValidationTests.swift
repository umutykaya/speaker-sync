import Testing
@testable import ssyncd

@Suite struct ValidationTests {
    @Test func delayBounds() throws {
        #expect(try Validate.delayMs(0) == 0)
        #expect(try Validate.delayMs(2000) == 2000)
        #expect(throws: APIError.self) { try Validate.delayMs(-0.1) }
        #expect(throws: APIError.self) { try Validate.delayMs(2000.1) }
        #expect(throws: APIError.self) { try Validate.delayMs(.nan) }
        #expect(throws: APIError.self) { try Validate.delayMs(.infinity) }
    }

    @Test func gainAndSeekBounds() throws {
        #expect(throws: APIError.self) { try Validate.gain(1.01) }
        #expect(throws: APIError.self) { try Validate.gain(.nan) }
        #expect(try Validate.seek(10, duration: 10) == 10)
        #expect(throws: APIError.self) { try Validate.seek(10.5, duration: 10) }
        #expect(throws: APIError.self) { try Validate.seek(-1, duration: 10) }
    }

    @Test func outputSelection() throws {
        let present: Set = ["a", "b", "c"]
        #expect(try Validate.outputUIDs(["a", "b"], present: present) == ["a", "b"])
        #expect(throws: APIError.self) { try Validate.outputUIDs([], present: present) }
        #expect(throws: APIError.self) { try Validate.outputUIDs(["a", "b", "c"], present: present) }
        #expect(throws: APIError.self) { try Validate.outputUIDs(["a", "a"], present: present) }
        #expect(throws: APIError.self) { try Validate.outputUIDs(["x"], present: present) }
    }

    @Test func uploadNames() throws {
        #expect(try Validate.uploadName("Song One.MP3") == ("Song One.MP3", "mp3"))
        #expect(throws: APIError.self) { try Validate.uploadName("../etc/passwd.mp3") }
        #expect(throws: APIError.self) { try Validate.uploadName("dir/song.mp3") }
        #expect(throws: APIError.self) { try Validate.uploadName(".hidden.mp3") }
        #expect(throws: APIError.self) { try Validate.uploadName("song.exe") }
        #expect(throws: APIError.self) { try Validate.uploadName(nil) }
    }

    @Test func profileNames() throws {
        #expect(try Validate.profileName("  Living room 1 ") == "Living room 1")
        #expect(throws: APIError.self) { try Validate.profileName("") }
        #expect(throws: APIError.self) { try Validate.profileName("a/b") }
        #expect(throws: APIError.self) { try Validate.profileName(String(repeating: "x", count: 41)) }
    }

    @Test func matchByUIDThenUniqueName() {
        let saved = [SavedOutput(uid: "old-go4", name: "JBL Go 4", delayMs: 12, gain: 1),
                     SavedOutput(uid: "charge", name: "JBL Charge 5", delayMs: 0, gain: 0.8)]
        let present = [PresentDevice(uid: "charge", name: "JBL Charge 5"), PresentDevice(uid: "new-go4", name: "JBL Go 4")]
        let m = matchOutputs(saved, present: present)
        #expect(m[0].uid == "new-go4" && m[0].kind == .name)
        #expect(m[1].uid == "charge" && m[1].kind == .uid)
    }

    @Test func ambiguousNameIsMissing() {
        let saved = [SavedOutput(uid: "gone", name: "JBL Go 4", delayMs: 0, gain: 1)]
        let present = [PresentDevice(uid: "x", name: "JBL Go 4"), PresentDevice(uid: "y", name: "JBL Go 4")]
        #expect(matchOutputs(saved, present: present)[0].kind == .missing)
    }

    @Test func tokenCompare() {
        #expect(tokensEqual("abc", "abc"))
        #expect(!tokensEqual("abc", "abd"))
        #expect(!tokensEqual("abc", "abcd"))
    }

    @Test func localNetworkFilter() {
        for ip in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.178.20", "169.254.1.1",
                   "::1", "fe80::1", "fd12::1", "::ffff:192.168.1.5"] {
            #expect(isLocalNetworkAddress(ip), "\(ip)")
        }
        for ip in ["8.8.8.8", "172.32.0.1", "11.0.0.1", "2001:db8::1", "::ffff:8.8.8.8", "garbage"] {
            #expect(!isLocalNetworkAddress(ip), "\(ip)")
        }
    }
}
