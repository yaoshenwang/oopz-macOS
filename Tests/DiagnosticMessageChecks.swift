let nickname = "A person's arbitrary nickname"
let opaqueToken = "opaque-secret-with-no-recognizable-format"
let message: DiagnosticMessage = "joined user=\(nickname) token=\(opaqueToken) count=\(3)"
precondition(message.text == "joined user=[private] token=[private] count=[private]")
precondition(!message.text.contains(nickname) && !message.text.contains(opaqueToken))
let nested: DiagnosticMessage = "error=\(message)"
precondition(nested.text == "error=[private]")
let plain: DiagnosticMessage = "voice left"
precondition(plain.text == "voice left")
print("PASS: diagnostic interpolation never serializes private values")
