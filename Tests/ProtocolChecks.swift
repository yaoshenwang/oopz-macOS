let url = URL(string: "https://example.invalid/path?q=one%20two")!
precondition(OopzSign.canonical("GET", url: url, body: "ignored") == "/path?q=one%20two")
precondition(OopzSign.canonical("POST", url: url, body: "{}") == "/path?q=one%20two{}")
precondition(String(data: OopzSign.signedData(canonical: "", timeMs: "123"), encoding: .utf8) == "d41d8cd98f00b204e9800998ecf8427e123")
let malformed: [[UInt8]] = [[], [0x30], [0x30, 0x82], [0x30, 0x82, 0xff, 0xff], [0x30, 0x02, 0x02, 0x01], [0x30, 0x80]]
for bytes in malformed { precondition((try? OopzSign.pkcs8Strip(Data(bytes))) == nil) }
print("PASS: canonical signing input and truncated DER rejection")
