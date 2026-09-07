import JavaScriptCore

func context(host: String) -> JSContext {
    let context = JSContext()!
    context.evaluateScript("""
    var location = {protocol:'https:', hostname:'\(host)'};
    var messages = [], calls = [], tick;
    var savedSession = {uid:'synthetic-user', signature:'synthetic-signature'};
    var localStorage = {getItem: function(){return JSON.stringify(savedSession);}};
    var btoa = function(s){return 'bytes:' + Array.from(s).map(function(c){return c.charCodeAt(0);}).join(',');};
    var setInterval = function(f){tick=f;};
    var window = {
      crypto:{subtle:{importKey:function(){calls.push(Array.from(arguments));return 'original-return-value';}}},
      webkit:{messageHandlers:{oopzLogin:{postMessage:function(m){messages.push(m);}}}}
    };
    """)
    context.evaluateScript(WebLoginBridge.script)
    precondition(context.exception == nil)
    return context
}
let official = context(host: "web.oopz.cn")
official.evaluateScript("""
var backing = new Uint8Array([9,1,2,3,9]);
var result = window.crypto.subtle.importKey('pkcs8', new Uint8Array(backing.buffer,1,3), {name:'RSASSA-PKCS1-v1_5'}, false, ['sign']);
tick(); tick();
""")
precondition(official.exception == nil)
precondition(official.evaluateScript("result === 'original-return-value' && calls.length === 1 && calls[0][3] === false")!.toBool())
precondition(official.evaluateScript("messages.length === 1 && messages[0].protocolKey === 'bytes:1,2,3'")!.toBool())
official.evaluateScript("savedSession = {uid:'synthetic-user',signature:'renewed'}; tick();")
precondition(official.evaluateScript("messages.length === 2")!.toBool())
let unrelated = context(host: "example.invalid")
unrelated.evaluateScript("window.crypto.subtle.importKey('pkcs8', new Uint8Array([1]), 'RSASSA-PKCS1-v1_5', true, ['sign']);")
precondition(unrelated.evaluateScript("messages.length === 0 && typeof tick === 'undefined'")!.toBool())
let otherKey = context(host: "web.oopz.cn")
otherKey.evaluateScript("window.crypto.subtle.importKey('raw', new Uint8Array([1]), 'AES-GCM', false, ['encrypt']); tick();")
precondition(otherKey.evaluateScript("messages.length === 0")!.toBool())
print("PASS: official login origin, WebCrypto pass-through, typed-array boundaries and session deduplication")
