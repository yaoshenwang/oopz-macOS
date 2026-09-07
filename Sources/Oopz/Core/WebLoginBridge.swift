import Foundation

/// Observe only the isolated official login page's existing protocol key import and session.
/// The original WebCrypto call, arguments and return value remain unchanged.
enum WebLoginBridge {
    static let script = #"""
    (() => {
      if (location.protocol !== 'https:' || location.hostname !== 'web.oopz.cn') return;
      const subtle = window.crypto && window.crypto.subtle;
      if (!subtle) return;
      const original = subtle.importKey.bind(subtle);
      let protocolKey = '';
      let sent = '';
      function deliver() {
        try {
          const session = JSON.parse(localStorage.getItem('session__OopzSession') || 'null');
          if (!session || typeof session.uid !== 'string' || typeof session.signature !== 'string' || !protocolKey) return;
          if (!session.uid || !session.signature || sent === session.uid + ':' + session.signature) return;
          window.webkit.messageHandlers.oopzLogin.postMessage({uid: session.uid, signature: session.signature, protocolKey});
          sent = session.uid + ':' + session.signature;
        } catch (_) {}
      }
      subtle.importKey = function(format, keyData, algorithm, extractable, usages) {
        const result = original(format, keyData, algorithm, extractable, usages);
        try {
          const name = typeof algorithm === 'string' ? algorithm : algorithm && algorithm.name;
          if (format === 'pkcs8' && name === 'RSASSA-PKCS1-v1_5' && usages && usages.includes('sign')) {
            const bytes = ArrayBuffer.isView(keyData)
              ? new Uint8Array(keyData.buffer, keyData.byteOffset, keyData.byteLength)
              : new Uint8Array(keyData);
            let binary = '';
            for (const byte of bytes) binary += String.fromCharCode(byte);
            protocolKey = btoa(binary);
            deliver();
          }
        } catch (_) {}
        return result;
      };
      setInterval(deliver, 750);
    })();
    """#
}
