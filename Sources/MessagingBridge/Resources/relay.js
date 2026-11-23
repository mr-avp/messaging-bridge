    (() => {
      if (location.hostname !== 'web.max.ru') return;
      const emitToHost = x => {
        if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
          window.chrome.webview.postMessage(x);
        } else if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.relay) {
          window.webkit.messageHandlers.relay.postMessage(x);
        }
      };
      const post = x => { try { emitToHost(x); } catch (_) {} };
      const Native = window.WebSocket;
      const allowed = h => h === 'oneme.ru' || h === 'max.ru' || h.endsWith('.oneme.ru') || h.endsWith('.max.ru');
      const td = new TextDecoder('utf-8');
      const te = new TextEncoder();

      function decodeMsgpack(bytes) {
        let pos = 0;
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const need = n => { if (pos + n > bytes.length) throw new Error('msgpack eof'); };
        const readStr = n => { need(n); const s = td.decode(bytes.subarray(pos, pos + n)); pos += n; return s; };
        const readMap = n => {
          const o = {};
          for (let i = 0; i < n; i++) {
            const k = decode();
            o[typeof k === 'string' ? k : String(k)] = decode();
          }
          return o;
        };
        const readArr = n => {
          const a = [];
          for (let i = 0; i < n; i++) a.push(decode());
          return a;
        };
        const readExt = (n, type) => {
          need(n);
          const data = bytes.subarray(pos, pos + n);
          pos += n;
          if (type !== 1) return null;
          const v = decodeMsgpack(data);
          if (typeof v === 'bigint' && v <= 9007199254740991n && v >= -9007199254740991n) return Number(v);
          return v;
        };
        const readUint = n => {
          let v = 0;
          for (let i = 0; i < n; i++) v = v * 256 + bytes[pos++];
          return v;
        };
        function decode() {
          need(1);
          const b = bytes[pos++];
          if (b <= 0x7f) return b;
          if (b >= 0xe0) return b - 0x100;
          if (b >= 0x80 && b <= 0x8f) return readMap(b & 0x0f);
          if (b >= 0x90 && b <= 0x9f) return readArr(b & 0x0f);
          if (b >= 0xa0 && b <= 0xbf) return readStr(b & 0x1f);
          switch (b) {
            case 0xc0: return null;
            case 0xc2: return false;
            case 0xc3: return true;
            case 0xc4: need(1); return readBin(bytes[pos++]);
            case 0xc5: need(2); return readBin((bytes[pos] << 8) | bytes[pos + 1], 2);
            case 0xc6: need(4); return readBin((bytes[pos] * 16777216) + ((bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3]), 4);
            case 0xc7: need(1); { const n = bytes[pos++]; need(1); return readExt(n, bytes[pos++]); }
            case 0xc8: need(2); { const n = (bytes[pos] << 8) | bytes[pos + 1]; pos += 2; need(1); return readExt(n, bytes[pos++]); }
            case 0xc9: need(4); { const n = (bytes[pos] * 16777216) + ((bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3]); pos += 4; need(1); return readExt(n, bytes[pos++]); }
            case 0xca: need(4); { const v = view.getFloat32(pos); pos += 4; return v; }
            case 0xcb: need(8); { const v = view.getFloat64(pos); pos += 8; return v; }
            case 0xcc: need(1); return bytes[pos++];
            case 0xcd: need(2); { const v = view.getUint16(pos); pos += 2; return v; }
            case 0xce: need(4); { const v = view.getUint32(pos); pos += 4; return v; }
            case 0xcf: need(8); { const v = view.getBigUint64(pos); pos += 8; return v <= 9007199254740991n ? Number(v) : v; }
            case 0xd0: need(1); { const v = view.getInt8(pos); pos += 1; return v; }
            case 0xd1: need(2); { const v = view.getInt16(pos); pos += 2; return v; }
            case 0xd2: need(4); { const v = view.getInt32(pos); pos += 4; return v; }
            case 0xd3: need(8); { const v = view.getBigInt64(pos); pos += 8; return v <= 9007199254740991n && v >= -9007199254740991n ? Number(v) : v; }
            case 0xd4: need(1); return readExt(1, bytes[pos++]);
            case 0xd5: need(1); return readExt(2, bytes[pos++]);
            case 0xd6: need(1); return readExt(4, bytes[pos++]);
            case 0xd7: need(1); return readExt(8, bytes[pos++]);
            case 0xd8: need(1); return readExt(16, bytes[pos++]);
            case 0xd9: need(1); return readStr(bytes[pos++]);
            case 0xda: need(2); { const n = view.getUint16(pos); pos += 2; return readStr(n); }
            case 0xdb: need(4); { const n = view.getUint32(pos); pos += 4; return readStr(n); }
            case 0xdc: need(2); { const n = view.getUint16(pos); pos += 2; return readArr(n); }
            case 0xdd: need(4); { const n = view.getUint32(pos); pos += 4; return readArr(n); }
            case 0xde: need(2); { const n = view.getUint16(pos); pos += 2; return readMap(n); }
            case 0xdf: need(4); { const n = view.getUint32(pos); pos += 4; return readMap(n); }
            default: throw new Error('msgpack byte 0x' + b.toString(16));
          }
        }
        function readBin(n, width) {
          if (width) pos += width;
          need(n);
          const out = bytes.subarray(pos, pos + n);
          pos += n;
          return out;
        }
        return decode();
      }

      function encodeMsgpack(value) {
        const out = [];
        const byte = n => { out.push(n & 255); };
        const bytes = arr => { for (let i = 0; i < arr.length; i++) out.push(arr[i]); };
        const big = n => {
          const b = new Uint8Array(8);
          const v = new DataView(b.buffer);
          if (n >= 0n) { byte(0xcf); v.setBigUint64(0, n); }
          else { byte(0xd3); v.setBigInt64(0, n); }
          bytes(b);
        };
        const number = n => {
          if (!Number.isFinite(n)) { const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, n); byte(0xcb); bytes(b); return; }
          if (!Number.isInteger(n) || !Number.isSafeInteger(n)) { const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, n); byte(0xcb); bytes(b); return; }
          if (n >= 0) {
            if (n <= 0x7f) byte(n);
            else if (n <= 0xff) { byte(0xcc); byte(n); }
            else if (n <= 0xffff) { byte(0xcd); byte(n >> 8); byte(n); }
            else if (n <= 0xffffffff) { byte(0xce); byte(n >>> 24); byte(n >>> 16); byte(n >>> 8); byte(n); }
            else big(BigInt(n));
          } else {
            if (n >= -32) byte(n);
            else if (n >= -128) { byte(0xd0); byte(n); }
            else if (n >= -32768) { byte(0xd1); byte(n >> 8); byte(n); }
            else if (n >= -2147483648) { byte(0xd2); byte(n >> 24); byte(n >> 16); byte(n >> 8); byte(n); }
            else big(BigInt(n));
          }
        };
        const string = s => {
          const b = te.encode(s);
          if (b.length <= 31) byte(0xa0 | b.length);
          else if (b.length <= 0xff) { byte(0xd9); byte(b.length); }
          else if (b.length <= 0xffff) { byte(0xda); byte(b.length >> 8); byte(b.length); }
          else { byte(0xdb); byte(b.length >>> 24); byte(b.length >>> 16); byte(b.length >>> 8); byte(b.length); }
          bytes(b);
        };
        const array = a => {
          if (a.length <= 15) byte(0x90 | a.length);
          else if (a.length <= 0xffff) { byte(0xdc); byte(a.length >> 8); byte(a.length); }
          else { byte(0xdd); byte(a.length >>> 24); byte(a.length >>> 16); byte(a.length >>> 8); byte(a.length); }
          for (const v of a) encode(v);
        };
        const map = o => {
          const keys = Object.keys(o).filter(k => o[k] !== undefined);
          if (keys.length <= 15) byte(0x80 | keys.length);
          else if (keys.length <= 0xffff) { byte(0xde); byte(keys.length >> 8); byte(keys.length); }
          else { byte(0xdf); byte(keys.length >>> 24); byte(keys.length >>> 16); byte(keys.length >>> 8); byte(keys.length); }
          for (const k of keys) { string(k); encode(o[k]); }
        };
        const encode = v => {
          if (v === null || v === undefined) { byte(0xc0); return; }
          if (v === true) { byte(0xc3); return; }
          if (v === false) { byte(0xc2); return; }
          if (typeof v === 'bigint') { big(v); return; }
          if (typeof v === 'number') { number(v); return; }
          if (typeof v === 'string') { string(v); return; }
          if (v instanceof Uint8Array) {
            if (v.length <= 0xff) { byte(0xc4); byte(v.length); }
            else if (v.length <= 0xffff) { byte(0xc5); byte(v.length >> 8); byte(v.length); }
            else { byte(0xc6); byte(v.length >>> 24); byte(v.length >>> 16); byte(v.length >>> 8); byte(v.length); }
            bytes(v);
            return;
          }
          if (Array.isArray(v)) { array(v); return; }
          if (typeof v === 'object') { map(v); return; }
          throw new Error('cannot encode ' + typeof v);
        };
        encode(value);
        return Uint8Array.from(out);
      }

      function lz4Decompress(src, maxOut) {
        const dst = new Uint8Array(maxOut);
        let sp = 0, dp = 0;
        while (sp < src.length) {
          const token = src[sp++];
          let lit = token >>> 4;
          if (lit === 15) { let s; do { if (sp >= src.length) throw new Error('lz4'); s = src[sp++]; lit += s; } while (s === 255); }
          if (sp + lit > src.length || dp + lit > dst.length) throw new Error('lz4 lit');
          dst.set(src.subarray(sp, sp + lit), dp);
          sp += lit; dp += lit;
          if (sp >= src.length) break;
          if (sp + 2 > src.length) throw new Error('lz4 offset');
          const off = src[sp++] | (src[sp++] << 8);
          if (off === 0 || off > dp) throw new Error('lz4 offset');
          let len = (token & 15) + 4;
          if ((token & 15) === 15) { let s; do { if (sp >= src.length) throw new Error('lz4'); s = src[sp++]; len += s; } while (s === 255); }
          if (dp + len > dst.length) throw new Error('lz4 match');
          let from = dp - off;
          for (let i = 0; i < len; i++) dst[dp++] = dst[from++];
        }
        return dst.subarray(0, dp);
      }

      const toU8 = data => {
        if (data instanceof Uint8Array) return data;
        if (data instanceof ArrayBuffer) return new Uint8Array(data);
        if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        return null;
      };

      function parseFrame(data) {
        const raw = toU8(data);
        if (!raw || raw.length < 10) return null;
        const h = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
        const f = { ver: raw[0], cmd: raw[1], seq: h.getInt16(2), opcode: h.getInt16(4), comp: raw[6], len: (raw[7] << 16) | (raw[8] << 8) | raw[9], payload: null };
        if (f.len > 0 && 10 + f.len <= raw.length) {
          let body = raw.subarray(10, 10 + f.len);
          try {
            if (f.comp > 0) body = lz4Decompress(body, f.len * f.comp);
            f.payload = decodeMsgpack(body);
          } catch (e) {
            f.error = String(e && e.message ? e.message : e);
          }
        }
        return f;
      }

      function makeFrame(cmd, seq, opcode, payload) {
        const body = payload === undefined ? new Uint8Array(0) : encodeMsgpack(payload);
        const out = new Uint8Array(10 + body.length);
        const h = new DataView(out.buffer);
        out[0] = 10; out[1] = cmd; h.setInt16(2, seq); h.setInt16(4, opcode); out[6] = 0;
        out[7] = (body.length >>> 16) & 255; out[8] = (body.length >>> 8) & 255; out[9] = body.length & 255;
        out.set(body, 10);
        return out;
      }

      const marker = String.fromCharCode(0x2063, 0x200B, 0x2063, 0x200B, 0x2063);
      const state = { chat: '', enabled: false, socket: null, sockets: new Set(), seq: -30000, pending: new Map(), wsCount: 0, wsHost: '', loggedIn: false, counts: {}, since: Date.now() - 3000, refresh: null, seen: new Set(), sentIds: new Set(), groupMap: new Map(), contactNames: new Map() };
      window.familyRelay = state;
      post({kind:'debug', stage:'start', host: location.hostname});

      const nextSeq = () => {
        for (let i = 0; i < 30000; i++) {
          state.seq += 1;
          if (state.seq >= 0) state.seq = -30000;
          if (!state.pending.has(state.seq)) return state.seq;
        }
        return -1;
      };

      const groupsOf = chats => {
        const list = Array.isArray(chats) ? chats : Object.values(chats || {});
        const seen = new Set();
        const out = [];
        for (const c of list) {
          if (!c || c.type !== 'CHAT' || c.status === 'REMOVED') continue;
          const id = String(c.id);
          if (seen.has(id)) continue;
          seen.add(id);
          out.push({id, title: String(c.title || c.name || id)});
        }
        return out;
      };

      const asString = value => {
        if (value === null || value === undefined) return '';
        if (typeof value === 'string') return value;
        if (typeof value === 'bigint' || typeof value === 'number' || typeof value === 'boolean') return String(value);
        return '';
      };
      const bigintOrNull = value => {
        if (typeof value === 'bigint') return value;
        if (typeof value === 'number' && Number.isFinite(value)) return BigInt(Math.trunc(value));
        const text = asString(value);
        return /^-?\d+$/.test(text) ? BigInt(text) : null;
      };
      const nameFromNames = names => {
        if (!Array.isArray(names)) return '';
        const textOf = n => {
          const direct = asString(n && (n.name || n.displayName));
          if (direct) return direct;
          if (!n) return '';
          return [asString(n.firstName), asString(n.lastName)].filter(Boolean).join(' ').trim();
        };
        for (const type of ['CUSTOM', 'ONEME']) {
          const found = names.find(n => n && asString(n.type) === type && textOf(n));
          if (found) return textOf(found);
        }
        for (const n of names) { const text = textOf(n); if (text) return text; }
        return '';
      };
      const rememberContacts = payload => {
        if (!payload || typeof payload !== 'object') return;
        const add = contact => {
          if (!contact || typeof contact !== 'object') return;
          const id = asString(contact.id ?? contact.userId ?? contact.contactId);
          const name = nameFromNames(contact.names) || asString(contact.name || contact.displayName)
            || [asString(contact.firstName), asString(contact.lastName)].filter(Boolean).join(' ').trim();
          if (id && name && !state.contactNames.has(id)) state.contactNames.set(id, name);
        };
        if (Array.isArray(payload.contacts)) payload.contacts.forEach(add);
        if (payload.profile && payload.profile.contact) add(payload.profile.contact);
        if (Array.isArray(payload.users)) payload.users.forEach(add);
        if (Array.isArray(payload.profiles)) payload.profiles.forEach(add);
        for (const chat of (Array.isArray(payload.chats) ? payload.chats : [])) {
          for (const list of [chat.participants, chat.members, chat.users]) {
            if (!Array.isArray(list)) continue;
            for (const item of list) add(item && typeof item === 'object' ? (item.contact || item.user || item) : null);
          }
        }
      };
      const contactIdsFromChats = chats => {
        const ids = new Set();
        for (const chat of (Array.isArray(chats) ? chats : [])) {
          if (chat && chat.participants && typeof chat.participants === 'object' && !Array.isArray(chat.participants)) {
            for (const key of Object.keys(chat.participants)) if (/^-?\d+$/.test(key)) ids.add(key);
          }
          if (Array.isArray(chat.participants)) for (const item of chat.participants) {
            const id = asString(item && (item.id ?? item.userId ?? item.contactId));
            if (id) ids.add(id);
          }
        }
        return ids;
      };
      const fetchContacts = async ids => {
        const unknown = Array.from(ids || []).filter(id => !state.contactNames.has(String(id)));
        if (!unknown.length) return;
        try {
          const payload = await request(32, {contactIds: unknown.map(bigintOrNull), contactType: 'USER', chatId: bigintOrNull(state.chat)}, 'contacts', 2000);
          rememberContacts(payload);
        } catch (_) {}
      };
      const senderName = message => {
        if (!message) return 'Участник MAX';
        const sender = message.sender;
        if (sender && typeof sender === 'object') {
          const direct = asString(sender.name || sender.displayName || sender.title || sender.firstName)
            || [asString(sender.firstName), asString(sender.lastName)].filter(Boolean).join(' ').trim();
          if (direct) return direct;
          const id = asString(sender.id ?? sender.userId ?? sender.contactId);
          return (id && state.contactNames.get(id)) || 'Участник MAX';
        }
        const direct = asString(message.senderName || message.userName || message.authorName);
        const id = asString(sender);
        return direct || (id && state.contactNames.get(id)) || 'Участник MAX';
      };
      const urlOf = value => {
        if (typeof value === 'string') return /^https?:\/\//i.test(value) ? value : '';
        if (value && typeof value === 'object') {
          for (const key of ['original', 'url', 'href', 'baseUrl']) {
            const found = urlOf(value[key]);
            if (found) return found;
          }
        }
        return '';
      };
      const mediaFromAttach = (attach, message, chat) => {
        if (!attach || typeof attach !== 'object') return null;
        const type = asString(attach._type);
        if (type === 'PHOTO') {
          const url = urlOf(attach.baseUrl || attach.url || attach.previewUrl);
          return url ? {kind: 'photo', url: url} : null;
        }
        if (type === 'VIDEO') {
          const token = asString(attach.token);
          const videoId = bigintOrNull(attach.videoId ?? attach.id);
          return token && videoId !== null
            ? {kind: 'video', videoId: videoId.toString(), token: token}
            : null;
        }
        if (type === 'FILE') {
          const url = urlOf(attach.url || attach.baseUrl || attach.previewUrl);
          const name = asString(attach.name);
          if (url) return {kind: 'file', url: url, name: name};
          const fileId = bigintOrNull(attach.fileId ?? attach.id);
          if (fileId !== null) {
            return {kind: 'file', fileId: fileId.toString(), chatId: asString(chat), messageId: asString(message && message.id), name: name};
          }
          return null;
        }
        return null;
      };
      const resolveMedia = async (items, chat, messageId) => {
        const out = [];
        for (const item of items) {
          if (item.kind === 'photo') { out.push({kind: 'photo', url: item.url}); continue; }
          if (item.kind === 'file' && item.url) { out.push({kind: 'file', url: item.url, name: item.name}); continue; }
          try {
            if (item.kind === 'video') {
              const payload = await request(83, {
                videoId: bigintOrNull(item.videoId),
                token: item.token,
                chatId: bigintOrNull(chat),
                postId: 0n,
                messageId: bigintOrNull(messageId)
              });
              const url = urlOf(payload && (payload.MP4_720 || payload.MP4_480 || payload.MP4_360 || payload.MP4_240 || payload.MP4_144 || payload.DASH || payload.HLS || payload.EXTERNAL));
              if (url) out.push({kind: 'video', url: url});
              else post({kind:'debug', stage:'media', error:'video url missing'});
            } else if (item.kind === 'file') {
              const payload = await request(88, {
                fileId: bigintOrNull(item.fileId),
                chatId: bigintOrNull(item.chatId || chat),
                messageId: bigintOrNull(item.messageId || messageId),
                itemType: 'REGULAR'
              });
              const url = urlOf(payload && payload.url);
              if (url) out.push({kind: 'file', url: url, name: item.name});
              else post({kind:'debug', stage:'media', error:'file url missing'});
            }
          } catch (_) {
            post({kind:'debug', stage:'media', error:'media url failed'});
          }
        }
        return out;
      };

      const wire = (f, type) => {
        const key = f.opcode + ':' + f.cmd;
        state.counts[key] = (state.counts[key] || 0) + 1;
        state.lastFrame = key;
        if (f.opcode === 128) return;
        post({kind:'debug', stage:'frame', opcode:f.opcode, cmd:f.cmd, seq:f.seq, len:f.len, comp:f.comp, type:type || '', error:f.error || '', groups: groupsOf(f.payload && f.payload.chats).length});
      };

      const settle = f => {
        const pending = state.pending.get(f.seq);
        if (!pending || pending.opcode !== f.opcode || (f.cmd !== 1 && f.cmd !== 3)) return false;
        clearTimeout(pending.timer);
        state.pending.delete(f.seq);
        if (f.cmd === 3 || (f.payload && f.payload.error)) pending.reject(new Error('rejected'));
        else pending.resolve(f.payload || {});
        return true;
      };

      const request = (opcode, payload, kind, timeoutMs) => new Promise((resolve, reject) => {
        if (!state.socket || state.socket.readyState !== 1) return reject(new Error('offline'));
        const seq = nextSeq();
        const timer = setTimeout(() => { state.pending.delete(seq); reject(new Error('timeout')); }, timeoutMs || 15000);
        state.pending.set(seq, {resolve, reject, timer, kind, opcode});
        try { state.socket.send(makeFrame(0, seq, opcode, payload)); }
        catch (_) { clearTimeout(timer); state.pending.delete(seq); reject(new Error('offline')); }
      });

      const applyGroups = (chats, kind) => {
        for (const g of groupsOf(chats)) state.groupMap.set(g.id, g.title);
        const all = Array.from(state.groupMap, ([id, title]) => ({id, title}));
        if (all.length) post({kind: kind, groups: all});
        return all;
      };

      state.refreshGroups = () => {
        if (state.refresh) return state.refresh;
        state.refresh = request(53, {marker: Date.now(), count: 100}, 'groups')
          .then(p => applyGroups(p.chats, 'groups'))
          .finally(() => { state.refresh = null; });
        return state.refresh;
      };

      const recordSent = payload => {
        const id = payload && payload.message && payload.message.id;
        if (id !== undefined && id !== null) {
          state.sentIds.add(String(id));
          if (state.sentIds.size > 5000) state.sentIds.clear();
        }
        return true;
      };
      const bytesFromBase64 = value => {
        const binary = atob(value);
        const out = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
        return out;
      };
      const uploadResult = async response => {
        const text = await response.text();
        if (response.status !== 200 && response.status !== 201) throw new Error('upload ' + response.status);
        try { return JSON.parse(text || '{}') || {}; } catch (_) { return {}; }
      };

      state.send = (chat, text) => {
        if (!state.enabled || !state.loggedIn || String(chat) !== String(state.chat)) return Promise.reject(new Error('offline'));
        const id = Number(chat);
        if (!Number.isSafeInteger(id)) return Promise.reject(new Error('chat'));
        return request(64, {
          chatId: id,
          message: {text: text, cid: Date.now() * 1000 + Math.floor(Math.random() * 1000), elements: [], attaches: []},
          notify: true
        }, 'send').then(recordSent);
      };

      state.sendMedia = async (chat, kind, base64, text, fileName) => {
        if (!state.enabled || !state.loggedIn || String(chat) !== String(state.chat)) throw new Error('offline');
        const id = Number(chat);
        if (!Number.isSafeInteger(id)) throw new Error('chat');
        const bytes = bytesFromBase64(base64);
        let attach;
        if (kind === 'photo') {
          const ack = await request(80, {count: 1}, 'upload-url');
          if (!ack || !ack.url) throw new Error('upload url');
          const form = new FormData();
          form.append('file', new Blob([bytes], {type: 'image/jpeg'}), fileName || 'photo.jpg');
          const uploaded = await uploadResult(await fetch(ack.url, {method: 'POST', body: form}));
          const photos = uploaded.photos;
          const token = Array.isArray(photos) ? (photos[0] && photos[0].token)
            : (photos && typeof photos === 'object' ? (Object.values(photos)[0] || {}).token : '');
          if (!token) throw new Error('photo token');
          attach = {_type: 'PHOTO', photoToken: String(token)};
        } else if (kind === 'video') {
          const ack = await request(82, {count: 1}, 'upload-url');
          const info = ack && Array.isArray(ack.info) ? ack.info[0] : null;
          const videoId = info ? bigintOrNull(info.videoId) : null;
          if (!info || !info.url || !info.token || videoId === null) throw new Error('upload info');
          const headers = {
            'Content-Type': 'application/octet-stream',
            'Content-Disposition': 'attachment; filename=' + encodeURIComponent(fileName || 'video.mp4'),
            'Content-Range': 'bytes 0-' + (bytes.length - 1) + '/' + bytes.length
          };
          const uploaded = await uploadResult(await fetch(info.url, {method: 'POST', headers: headers, body: bytes}));
          attach = {_type: 'VIDEO', videoId: videoId, token: String(info.token)};
          if (uploaded && uploaded.thumbhash) attach.thumbhash = bytesFromBase64(uploaded.thumbhash);
        } else if (kind === 'file') {
          const ack = await request(87, {count: 1, length: bytes.length}, 'upload-url');
          const info = ack && Array.isArray(ack.info) ? ack.info[0] : null;
          const fileId = info ? bigintOrNull(info.fileId) : null;
          if (!info || !info.url || fileId === null) throw new Error('upload info');
          const headers = {
            'Content-Type': 'application/octet-stream',
            'Content-Disposition': 'attachment; filename=' + encodeURIComponent(fileName || 'file'),
            'Content-Range': 'bytes 0-' + (bytes.length - 1) + '/' + bytes.length
          };
          await uploadResult(await fetch(info.url, {method: 'POST', headers: headers, body: bytes}));
          attach = {_type: 'FILE', fileId: fileId, name: fileName || 'file'};
          if (info.token) attach.token = String(info.token);
        } else {
          throw new Error('media kind');
        }
        return request(64, {
          chatId: id,
          message: {text: text, cid: Date.now() * 1000 + Math.floor(Math.random() * 1000), elements: [], attaches: [attach]},
          notify: true
        }, 'send-media').then(recordSent);
      };

      const handlePush = payload => {
        rememberContacts(payload);
        const chat = asString(payload.chatId);
        if (chat !== asString(state.chat)) return;
        const m = payload.message;
        if (!m || m.id === undefined || m.id === null) return;
        if (m.status === 'EDITED' || m.status === 'REMOVED' || m.status === 'SPAM' || m.updateTime) return;
        const id = asString(m.id);
        if (state.sentIds.has(id)) return;
        const key = chat + ':' + id;
        if (state.seen.has(key)) return;
        state.seen.add(key);
        if (state.seen.size > 5000) state.seen.clear();
        const time = Number(m.time);
        if (!Number.isFinite(time) || time < state.since) return;
        const text = asString(m.text || m.caption || '');
        if (text.includes(marker) || text.includes('\u2063семейный-мост\u2063')) return;
        const raw = Array.isArray(m.attaches) ? m.attaches : (Array.isArray(m.attachments) ? m.attachments : []);
        const rawMedia = raw.map(a => mediaFromAttach(a, m, chat)).filter(Boolean);
        if (!text && !rawMedia.length) return;
        const initialSender = senderName(m);
        const senderId = asString((m && m.sender && typeof m.sender === 'object')
          ? (m.sender.id ?? m.sender.userId ?? m.sender.contactId)
          : m.sender);
        const proceed = sender => {
          const finish = media => {
            if (!text && !media.length) return;
            post({kind:'message', chat:chat, id:id, sender:sender, text:text, media:media});
          };
          resolveMedia(rawMedia, chat, id).then(finish).catch(() => {});
        };
        if (initialSender === 'Участник MAX' && /^-?\d+$/.test(senderId)) {
          fetchContacts(new Set([senderId])).then(() => proceed(state.contactNames.get(senderId) || initialSender)).catch(() => proceed(initialSender));
          return;
        }
        proceed(initialSender);
      };

      const onFrame = (f, type, ws) => {
        if (!f) return;
        wire(f, type);
        const p = f.payload && typeof f.payload === 'object' ? f.payload : {};
        if (settle(f)) return;

        if (f.cmd === 1 && f.opcode === 6) {
          post({kind:'debug', stage:'init'});
          return;
        }
        if (f.cmd === 1 && (f.opcode === 19 || f.opcode === 23)) {
          state.loggedIn = true;
          if (ws) state.socket = ws;
          rememberContacts(p);
          fetchContacts(contactIdsFromChats(p.chats)).catch(() => {});
          post({kind:'ready', opcode:f.opcode, groups: applyGroups(p.chats, 'groups')});
          state.refreshGroups().catch(() => {});
          return;
        }
        if (f.cmd === 3 && (f.opcode === 19 || f.opcode === 23)) {
          state.loggedIn = false;
          post({kind:'login-error', code:String(p.error || 'login')});
          return;
        }
        if (f.cmd === 1 && f.opcode === 53) {
          rememberContacts(p);
          fetchContacts(contactIdsFromChats(p.chats)).catch(() => {});
          applyGroups(p.chats, 'groups');
          return;
        }
        if (f.cmd === 0 && f.opcode === 128 && state.enabled) {
          handlePush(p);
        }
      };

      const handleMessage = (event, ws) => {
        if (event && event.__relay_handled) return;
        if (event) event.__relay_handled = true;
        const data = event ? event.data : null;
        if (typeof data === 'string') {
          post({kind:'debug', stage:'frame', opcode:0, cmd:0, seq:0, len:data.length, comp:0, type:'text', error:'unexpected text frame'});
          return;
        }
        if (typeof Blob !== 'undefined' && data instanceof Blob) {
          data.arrayBuffer().then(buf => onFrame(parseFrame(buf), 'blob', ws)).catch(() => {});
          return;
        }
        onFrame(parseFrame(data), 'binary', ws);
      };

      window.WebSocket = class extends Native {
        constructor(...args) {
          super(...args);
          try { this.binaryType = 'arraybuffer'; } catch (_) {}
          let host;
          try { host = new URL(String(args[0])).hostname; } catch (_) { host = String(args[0] || ''); }
          if (!allowed(host)) {
            post({kind:'debug', stage:'ws-skip', host: host});
            return;
          }
          state.sockets.add(this);
          if (!state.socket || state.socket.readyState !== 1) state.socket = this;
          state.wsCount = (state.wsCount || 0) + 1;
          state.wsHost = host;
          post({kind:'debug', stage:'ws', host: host, count: state.wsCount});
          this.addEventListener('message', e => { handleMessage(e, this); });
          this.addEventListener('close', () => {
            state.sockets.delete(this);
            if (state.socket === this) {
              state.socket = Array.from(state.sockets).find(s => s.readyState === 1) || null;
              state.enabled = false;
              state.loggedIn = false;
              post({kind:'disconnected'});
            }
          });
        }
      };

      state.__test = {decode: decodeMsgpack, encode: encodeMsgpack, parse: parseFrame, frame: makeFrame, lz4: lz4Decompress, groups: groupsOf};
    })();
    
