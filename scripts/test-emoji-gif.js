const fs = require('fs');
const vm = require('vm');
const assert = require('node:assert/strict');

// The Swift target embeds the relay script. Keep the two copies in sync outside
// the host adapter (WebKit on macOS, WebView2 on Windows).
const source = fs.readFileSync(__dirname + '/../Sources/MessagingBridge/MaxWeb.swift', 'utf8')
  .split('static let script = #"""')[1]
  .split('"""#')[0];
const resource = fs.readFileSync(__dirname + '/../Sources/MessagingBridge/Resources/relay.js', 'utf8');

const swiftPost = 'const post = x => { try { window.webkit.messageHandlers.relay.postMessage(x); } catch (_) {} };';
const resourcePost = `const emitToHost = x => {
        if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
          window.chrome.webview.postMessage(x);
        } else if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.relay) {
          window.webkit.messageHandlers.relay.postMessage(x);
        }
      };
      const post = x => { try { emitToHost(x); } catch (_) {} };`;

assert.ok(source.includes(swiftPost), 'Expected the Swift WebKit adapter');
assert.ok(resource.includes(resourcePost), 'Expected both host adapters');
assert.equal(resource.replace(resourcePost, swiftPost).trim(), source.trim(), 'Relay logic must match outside the host adapter');

const received = [];
const relayReceived = () => received.filter(x => x.kind !== 'debug');
const uploads = [];

class WS {
  constructor() {
    this.readyState = 1;
    this.handlers = {};
    this.sent = [];
    WS.last = this;
  }
  addEventListener(type, f) { (this.handlers[type] ||= []).push(f); }
  emit(frame) { for (const f of this.handlers.message || []) f({data: frame}); }
  close() { this.readyState = 3; for (const f of this.handlers.close || []) f(); }
  send(raw) { this.sent.push(raw); }
}

class FakeFormData {
  constructor() { this.fields = []; }
  append(name, value) { this.fields.push({name, value}); }
}
class FakeBlob {
  constructor(parts, options = {}) { this.parts = parts; this.type = options.type || ''; }
}

const sandbox = {
  location: {hostname: 'web.max.ru'},
  URL,
  TextDecoder,
  TextEncoder,
  atob: s => Buffer.from(s, 'base64').toString('binary'),
  Blob: FakeBlob,
  FormData: FakeFormData,
  fetch: async (url, options) => {
    uploads.push({url, options});
    if (options && options.headers) return {status: 200, text: async () => '{"thumbhash":"AA=="}'};
    return {status: 200, text: async () => '{"photos":{"1":{"token":"PHOTO_TOKEN"}}}'};
  },
  window: {
    WebSocket: WS,
    webkit: {messageHandlers: {relay: {postMessage: x => received.push(x)}}}
  },
  setTimeout,
  clearTimeout
};

vm.runInNewContext(source, sandbox);

const ws = new sandbox.window.WebSocket('wss://api.oneme.ru/websocket');
ws.addEventListener('message', () => {});
const relay = sandbox.window.familyRelay;
const t = relay.__test;
const parse = raw => t.parse(raw);
const emit = (cmd, seq, opcode, payload) => ws.emit(t.frame(cmd, seq, opcode, payload));
const sentOf = opcode => ws.sent.map(parse).filter(f => f && f.cmd === 0 && f.opcode === opcode);
const tick = () => new Promise(r => setTimeout(r, 0));
const message = (chat, text, time = 2000, extra = {}) => {
  const id = (message.next = (message.next || 100) + 1);
  return () => emit(0, 0, 128, {chatId: chat, message: {id, sender: 5, text, time, ...extra}});
};

const emojiCases = [
  ['single smiley', 'Hello 👋😀👍'],
  ['multiple smileys', '🙂😃😄😁😆😅🤣'],
  ['ZWJ family and professions', 'Семья 👨‍👩‍👧‍👦, врач 👩🏽‍⚕️ и космонавт 👩🏽‍🚀'],
  ['skin tones', '👍🏽👌🏿🤝🏻🙋🏾‍♂️'],
  ['flags and tag flag', '🇷🇺 🇺🇸 🇪🇺 🏴󠁧󠁢󠁥󠁮󠁧󠁿'],
  ['keycap and variation selector', '1️⃣ ❤️ ☺️ ✈️'],
  ['emoji with markup characters', '<Анна> & друзья 🚀✈️🌍'],
  ['combining accents', 'e\u0301 vs é, 👨🏿‍🤝‍👨🏻']
];

(async () => {
  relay.chat = '-100';
  relay.since = 1000;
  relay.enabled = true;
  emit(1, 0, 19, {
    contacts: [{id: 5, names: [{name: 'Анна', type: 'CUSTOM'}]}],
    chats: [{id: -100, type: 'CHAT', title: 'test_max'}]
  });
  assert.equal(relayReceived().at(-1).kind, 'ready');

  // 1. Every Unicode emoji form must reach the host byte-for-byte unchanged.
  for (const [label, text] of emojiCases) {
    message('-100', text)();
    await tick();
    assert.equal(relayReceived().at(-1).text, text, `${label}: emoji text must pass through unchanged`);
  }

  // 2. A GIF sent by MAX as a FILE keeps its name and MIME hint.
  message('-100', '', 2000, {
    attaches: [{_type: 'FILE', url: 'https://example.com/animation.gif', name: 'anim.gif', mimeType: 'image/gif'}]
  })();
  await tick();
  const fileMessage = relayReceived().at(-1);
  assert.equal(fileMessage.media[0].kind, 'file', 'GIF as FILE must be delivered as file media');
  assert.equal(fileMessage.media[0].url, 'https://example.com/animation.gif');
  assert.equal(fileMessage.media[0].name, 'anim.gif');
  assert.equal(fileMessage.media[0].mime, 'image/gif');

  // 3. A GIF sent by MAX as a VIDEO resolves through opcode 83 and keeps hints.
  message('-100', 'gif-video', 2000, {
    attaches: [{_type: 'VIDEO', videoId: 18162518875937, token: 'gif_token', name: 'anim.gif', mimeType: 'image/gif'}]
  })();
  const videoRequest = sentOf(83).at(-1);
  assert.ok(videoRequest, 'video source request must be sent for GIF-as-video');
  assert.equal(String(videoRequest.payload.videoId), '18162518875937');
  emit(1, videoRequest.seq, 83, {MP4_720: 'https://example.com/animation.mp4'});
  await tick();
  const videoMessage = relayReceived().at(-1);
  assert.equal(videoMessage.media[0].kind, 'video');
  assert.equal(videoMessage.media[0].url, 'https://example.com/animation.mp4');
  assert.equal(videoMessage.media[0].name, 'anim.gif');
  assert.equal(videoMessage.media[0].mime, 'image/gif');

  // 4. A bare isGif hint is enough to mark the media as a GIF.
  message('-100', '', 2000, {
    attaches: [{_type: 'VIDEO', videoId: 42, token: 'tok', isGif: true}]
  })();
  const gifRequest = sentOf(83).at(-1);
  assert.ok(gifRequest);
  emit(1, gifRequest.seq, 83, {MP4_480: 'https://example.com/loop.mp4'});
  await tick();
  assert.equal(relayReceived().at(-1).media[0].mime, 'image/gif');

  // 5. A normal MP4 video must not be misclassified as a GIF.
  message('-100', '', 2000, {attaches: [{_type: 'VIDEO', videoId: 43, token: 'tok2'}]})();
  const mp4Request = sentOf(83).at(-1);
  assert.ok(mp4Request);
  emit(1, mp4Request.seq, 83, {MP4_720: 'https://example.com/video.mp4'});
  await tick();
  const normalVideo = relayReceived().at(-1).media[0];
  assert.equal(normalVideo.kind, 'video');
  assert.equal(normalVideo.mime, undefined);
  assert.equal(normalVideo.name, undefined);

  // 6. A FILE without a public URL resolves through opcode 88.
  message('-100', '', 2000, {attaches: [{_type: 'FILE', fileId: 12345, name: 'document.pdf'}]})();
  const fileRequest = sentOf(88).at(-1);
  assert.ok(fileRequest, 'file URL request must be sent for a private FILE');
  emit(1, fileRequest.seq, 88, {url: 'https://example.com/document.pdf'});
  await tick();
  assert.equal(relayReceived().at(-1).media[0].url, 'https://example.com/document.pdf');

  // 7. MIME detection used for MAX uploads.
  assert.equal(t.mimeOf('A.GIF?token=1'), 'image/gif');
  assert.equal(t.mimeOf('clip.MP4'), 'video/mp4');
  assert.equal(t.mimeOf('photo.jpeg'), 'image/jpeg');
  assert.equal(t.mimeOf('report.pdf'), 'application/pdf');
  assert.equal(t.mimeOf('file'), '');

  // 7a. A MAX AUDIO attach must be visible in diagnostics, not silently
  // dropped. No voice URL resolution or native mapping is guessed here.
  const mediaDebugBefore = received.filter(x => x.kind === 'debug' && x.stage === 'media').length;
  const messagesBefore = relayReceived().length;
  message('-100', '', 2000, {attaches: [{_type: 'AUDIO', audioId: 991, token: 'audio_token'}]})();
  await tick();
  const audioDebug = received.filter(x => x.kind === 'debug' && x.stage === 'media');
  assert.equal(audioDebug.length, mediaDebugBefore + 1, 'AUDIO attach must produce a visible diagnostic');
  assert.match(audioDebug.at(-1).error, /AUDIO attach not relayed/);
  assert.equal(relayReceived().length, messagesBefore, 'unsupported AUDIO attach must not be forwarded');

  const uploadMedia = async (kind, fileName, mime) => {
    const promise = relay.sendMedia('-100', kind, Buffer.from('bytes').toString('base64'), 'подпись', fileName, mime);
    const opcode = kind === 'photo' ? 80 : kind === 'video' ? 82 : 87;
    const request = sentOf(opcode).at(-1);
    assert.ok(request, `${kind} upload URL request was not sent`);
    if (opcode === 80) emit(1, request.seq, 80, {url: 'https://upload.example/photo'});
    else if (opcode === 82) emit(1, request.seq, 82, {info: [{url: 'https://upload.example/video', videoId: 42, token: 'VIDEO_TOKEN'}]});
    else emit(1, request.seq, 87, {info: [{url: 'https://upload.example/file', fileId: 77, token: 'FILE_TOKEN'}]});
    await tick();
    const send = sentOf(64).at(-1);
    assert.ok(send, `${kind} send frame was not produced`);
    emit(1, send.seq, 64, {message: {id: 500 + opcode}});
    await promise;
    return {send, upload: uploads.at(-1)};
  };

  // 8. MAX uploads carry a useful Content-Type instead of octet-stream.
  const gifUpload = await uploadMedia('file', 'anim.gif', '');
  assert.equal(gifUpload.upload.options.headers['Content-Type'], 'image/gif');
  assert.ok(String(gifUpload.upload.options.headers['Content-Disposition']).includes('anim.gif'));
  assert.equal(gifUpload.send.payload.message.attaches[0]._type, 'FILE');

  const videoUpload = await uploadMedia('video', 'clip.mp4', '');
  assert.equal(videoUpload.upload.options.headers['Content-Type'], 'video/mp4');

  const pdfUpload = await uploadMedia('file', 'report.pdf', '');
  assert.equal(pdfUpload.upload.options.headers['Content-Type'], 'application/pdf');

  const explicitUpload = await uploadMedia('file', 'mystery.bin', 'image/gif');
  assert.equal(explicitUpload.upload.options.headers['Content-Type'], 'image/gif');

  const photoUpload = await uploadMedia('photo', 'photo.jpg', '');
  const photoForm = photoUpload.upload.options.body;
  assert.equal(photoForm.fields[0].value.type, 'image/jpeg');
  assert.equal(photoUpload.send.payload.message.attaches[0]._type, 'PHOTO');

  console.log(`Emoji, smiley and GIF relay tests passed: ${emojiCases.length} Unicode cases, GIF as FILE/VIDEO, MIME hints and upload Content-Type.`);
  ws.close();
  assert.equal(relay.enabled, false);
  assert.equal(relayReceived().at(-1).kind, 'disconnected');
})().catch(error => {
  console.error(error);
  process.exit(1);
});
