const fs = require('fs');
const vm = require('vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(__dirname + '/../Sources/MessagingBridge/MaxWeb.swift', 'utf8').split('static let script = #"""')[1].split('"""#')[0];
const resource = fs.readFileSync(__dirname + '/../Sources/MessagingBridge/Resources/relay.js', 'utf8');
// Windows WebView2 and macOS WebKit use different host postMessage adapters.
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
assert.ok(resource.includes(resourcePost), 'Expected both resource host adapters');
assert.equal(resource.replace(resourcePost, swiftPost).trim(), source.trim(), 'Relay logic must match outside the host adapter');
const received = [];
const relayReceived = () => received.filter(x => x.kind !== 'debug');
class WS {
  constructor() { this.readyState = 1; this.handlers = {}; this.sent = []; WS.last = this; }
  addEventListener(type, f) { (this.handlers[type] ||= []).push(f); }
  emit(frame) { for (const f of this.handlers.message || []) f({data:frame}); }
  close() { this.readyState = 3; for (const f of this.handlers.close || []) f(); }
  send(raw) { this.sent.push(raw); }
}
class FakeFormData { append() {} }
class FakeBlob { constructor() {} }
const sandbox = {location:{hostname:'web.max.ru'}, URL, TextDecoder, TextEncoder, atob: s => Buffer.from(s,'base64').toString('binary'), Blob: FakeBlob, FormData: FakeFormData, fetch: async (_url, options) => ({status:200, text: async () => options && options.headers ? '{"thumbhash":"AA=="}' : '{"photos":{"1":{"token":"PHOTO_TOKEN"}}}'}), window:{WebSocket:WS, webkit:{messageHandlers:{relay:{postMessage:x=>received.push(x)}}}}, setTimeout, clearTimeout};
vm.runInNewContext(source, sandbox);
const ws = new sandbox.window.WebSocket('wss://api.oneme.ru/websocket');
ws.addEventListener('message', () => {}); // simulate MAX web client handler
const relay = sandbox.window.familyRelay;
const t = relay.__test;
const parse = raw => t.parse(raw);
const emit = (cmd, seq, opcode, payload) => ws.emit(t.frame(cmd, seq, opcode, payload));
const sentOf = opcode => ws.sent.map(parse).filter(f => f && f.cmd === 0 && f.opcode === opcode);
const message = (chat, text, time=2000, extra={}) => { const id = (message.next = (message.next || 100) + 1); return () => emit(0, 0, 128, {chatId:chat,message:{id,sender:5,text,time,...extra}}); };

(async () => {
  assert.ok(relay, 'bridge state is missing');
  const decoded = t.decode(t.encode({a:-68062790150799,b:[1,'x'],c:{d:true}}));
  assert.equal(decoded.a, -68062790150799);
  assert.equal(JSON.stringify(decoded.b), '[1,"x"]');
  assert.equal(decoded.c.d, true);

  relay.chat = '-100'; relay.since=1000;
  const disabledCount = relayReceived().length;
  message('-100','disabled')(); assert.equal(relayReceived().length,disabledCount);
  relay.enabled = true;
  message('123','private code 123456')(); assert.equal(relayReceived().length,disabledCount);
  message('-100','old',500)(); assert.equal(relayReceived().length,disabledCount);
  message('-100','echo\u2063семейный-мост\u2063')(); assert.equal(relayReceived().length,disabledCount);
  message('-100','edited',2000,{status:'EDITED',updateTime:3000})(); assert.equal(relayReceived().length,disabledCount);
  message('-100','family')(); await new Promise(r => setTimeout(r, 2200)); assert.equal(relayReceived().length,disabledCount+1); assert.equal(relayReceived().at(-1).text,'family');

  emit(1, 0, 19, {token:'SECRET',contacts:[{id:5,names:[{name:'Анна',type:'CUSTOM'}]}],chats:[{id:-100,type:'CHAT',title:'test_max',lastMessage:{text:'DO NOT EXPORT'}},{id:123,type:'DIALOG',title:'PRIVATE'}]});
  assert.equal(relayReceived().at(-1).kind,'ready');
  assert.equal(relayReceived().at(-1).groups.length,1);
  message('-100','от участника')();
  await new Promise(r => setTimeout(r, 0));
  assert.equal(relayReceived().at(-1).sender,'Анна', 'MAX sender must use the contact name from login');
  message('-100','от неизвестного',2000,{sender:999})();
  await new Promise(r => setTimeout(r, 2200));
  assert.equal(relayReceived().at(-1).sender,'Участник MAX');

  const photoURL = 'https://i.oneme.ru/i?r=test&expires=1';
  message('-100','',2000,{attaches:[{_type:'PHOTO',baseUrl:photoURL}]})();
  await new Promise(r => setTimeout(r, 0));
  assert.equal(JSON.stringify(relayReceived().at(-1).media),JSON.stringify([{kind:'photo',url:photoURL}]));
  const ignoredCount = relayReceived().length;
  message('-100','',2000,{attaches:[{_type:'CONTROL',event:'title'}]})();
  await new Promise(r => setTimeout(r, 0));
  assert.equal(relayReceived().length,ignoredCount,'non-media attaches must be ignored');

  message('-100','видео',2000,{attaches:[{_type:'VIDEO',videoId:18162518875937,token:'tok'}]})();
  const videoRequest = sentOf(83).at(-1);
  assert.ok(videoRequest,'video source request was not sent');
  assert.equal(String(videoRequest.payload.videoId),'18162518875937');
  emit(1,videoRequest.seq,83,{MP4_720:'https://maxvd.example/video.mp4'});
  await new Promise(r => setTimeout(r, 0));
  assert.equal(relayReceived().at(-1).text,'видео');
  assert.equal(JSON.stringify(relayReceived().at(-1).media),JSON.stringify([{kind:'video',url:'https://maxvd.example/video.mp4'}]));
  const groupsRequest = sentOf(53)[0];
  assert.ok(groupsRequest, 'GET_CHATS request was not sent');
  assert.ok(groupsRequest.seq >= -32768 && groupsRequest.seq <= 32767, 'request seq does not fit int16');
  emit(1, groupsRequest.seq, 53, {chats:[{id:-100,type:'CHAT',title:'test_max'},{id:-200,type:'CHAT',title:'other'},{id:123,type:'DIALOG',title:'PRIVATE'}]});
  await new Promise(r => setTimeout(r, 0));
  const groups = relayReceived().filter(x => x.kind === 'groups').at(-1);
  assert.ok(groups, 'group refresh did not reach Swift');
  assert.equal(groups.groups.length,2);

  emit(1, 0, 23, {chats:[{id:-100,type:'CHAT',title:'test_max'}]});
  assert.equal(relayReceived().at(-1).kind,'ready', 'restored LOGIN_BY_TOKEN(23) must also mark ready');
  emit(1, 0, 53, {chats:[{id:-100,type:'CHAT',title:'test_max'}]});
  assert.equal(relayReceived().filter(x => x.kind === 'groups').at(-1).groups.length,2, 'partial GET_CHATS response must not drop known groups');

  const sending = relay.send('-100','hello');
  const sendFrame = sentOf(64)[0];
  assert.ok(sendFrame, 'MSG_SEND request was not sent');
  assert.ok(sendFrame.seq >= -32768 && sendFrame.seq <= 32767, 'seq is outside the protocol range');
  assert.equal(sendFrame.payload.chatId, -100);
  assert.equal(sendFrame.payload.message.text, 'hello');
  emit(1, sendFrame.seq, 64, {chatId:-100,message:{id:7,time:3000,text:'hello'}});
  assert.equal(await sending, true);
  const afterOwnSend = relayReceived().length;
  emit(0, 0, 128, {chatId:'-100',message:{id:7,sender:5,text:'эхо собственного ответа',time:3000}});
  assert.equal(relayReceived().length, afterOwnSend, 'our own acknowledged MAX message must not be echoed back');

  const sendingPhoto = relay.sendMedia('-100','photo',Buffer.from('img').toString('base64'),'фото','photo.jpg');
  const photoURLRequest = sentOf(80).at(-1);
  assert.ok(photoURLRequest,'photo upload URL request was not sent');
  emit(1,photoURLRequest.seq,80,{url:'https://upload.example/photo'});
  await new Promise(r => setTimeout(r, 0));
  const photoSend = sentOf(64).at(-1);
  assert.equal(photoSend.payload.message.attaches[0]._type,'PHOTO');
  assert.equal(photoSend.payload.message.attaches[0].photoToken,'PHOTO_TOKEN');
  emit(1,photoSend.seq,64,{message:{id:8}});
  assert.equal(await sendingPhoto,true);

  const sendingVideo = relay.sendMedia('-100','video',Buffer.from('vid').toString('base64'),'видео','video.mp4');
  const videoURLRequest = sentOf(82).at(-1);
  assert.ok(videoURLRequest,'video upload URL request was not sent');
  emit(1,videoURLRequest.seq,82,{info:[{url:'https://upload.example/video',videoId:42,token:'VIDEO_TOKEN'}]});
  await new Promise(r => setTimeout(r, 0));
  const videoSend = sentOf(64).at(-1);
  assert.equal(videoSend.payload.message.attaches[0]._type,'VIDEO');
  assert.equal(String(videoSend.payload.message.attaches[0].videoId),'42');
  assert.equal(videoSend.payload.message.attaches[0].token,'VIDEO_TOKEN');
  emit(1,videoSend.seq,64,{message:{id:9}});
  assert.equal(await sendingVideo,true);

  await assert.rejects(relay.send('123','nope'));

  assert.ok(!JSON.stringify(received).includes('SECRET'));
  assert.ok(!JSON.stringify(received).includes('DO NOT EXPORT'));
  assert.ok(!JSON.stringify(received).includes('PRIVATE'));
  ws.close(); assert.equal(relay.enabled,false);
  assert.equal(relayReceived().at(-1).kind,'disconnected');
  console.log('MAX boundary tests passed: binary v10 frame, signed 16-bit seq, msgpack codec, disabled, private chat, old/edited/echo message, real names, photo/video receive and upload, group metadata, restored login, send, disconnect.');
})().catch(error => { console.error(error); process.exit(1); });
