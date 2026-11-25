import Foundation

/// Limits published by the Telegram Bot API. They are checked before a file is
/// downloaded or uploaded so one oversized attachment cannot stop the bridge.
enum TelegramLimits {
    static let photoBytes = 10 * 1024 * 1024
    static let animationBytes = 50 * 1024 * 1024
    static let videoBytes = 50 * 1024 * 1024
    static let documentBytes = 50 * 1024 * 1024
    /// Bot API `getFile` is limited to 20 MB even when the original file is larger.
    static let botDownloadBytes = 20 * 1024 * 1024
    /// Telegram counts text in UTF-16 code units; emoji take two units each.
    static let captionUnits = 1024
    static let messageUnits = 4000

    static func maxBytes(for kind: TelegramMediaKind) -> Int {
        switch kind {
        case .photo: return photoBytes
        case .animation: return animationBytes
        case .video: return videoBytes
        case .document: return documentBytes
        }
    }

    static func canSend(kind: TelegramMediaKind, byteCount: Int) -> Bool {
        byteCount <= maxBytes(for: kind)
    }

    static func canDownload(byteCount: Int) -> Bool {
        byteCount <= botDownloadBytes
    }

    static func isTooBigDownload(_ error: Error) -> Bool {
        guard let tg = error as? TelegramError else { return false }
        let detail = tg.detail.lowercased()
        return detail.contains("too big") || detail.contains("file is too big")
    }
}

enum MediaInfo {
    private static let mimeByExtension: [String: String] = [
        "gif": "image/gif",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
        "heic": "image/heic",
        "heif": "image/heif",
        "bmp": "image/bmp",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "mp4": "video/mp4",
        "m4v": "video/x-m4v",
        "mov": "video/quicktime",
        "webm": "video/webm",
        "mkv": "video/x-matroska",
        "avi": "video/x-msvideo",
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "opus": "audio/ogg",
        "wav": "audio/wav",
        "pdf": "application/pdf",
        "zip": "application/zip",
        "txt": "text/plain",
        "json": "application/json"
    ]

    /// Lower-case extension for a file name or URL, ignoring query and fragment.
    static func fileExtension(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let path: String
        if let url = URL(string: value), !url.path.isEmpty {
            path = url.path
        } else {
            path = value.split(separator: "?", maxSplits: 1).first
                .map(String.init)?
                .split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        }
        let ext = (path as NSString).pathExtension
        return ext.lowercased()
    }

    static func mimeType(fileName: String) -> String {
        mimeByExtension[fileExtension(fileName)] ?? "application/octet-stream"
    }

    static func isGIF(name: String?, url: String?, mime: String?) -> Bool {
        if let mime, mime.lowercased().contains("gif") { return true }
        if let name, fileExtension(name) == "gif" { return true }
        if let url, fileExtension(url) == "gif" { return true }
        return false
    }

    /// Map a MAX attachment to the Telegram method that preserves its meaning.
    /// MAX has no separate animation type: GIFs arrive as VIDEO or FILE.
    static func telegramKind(
        for kind: RelayMediaKind,
        url: String?,
        name: String?,
        mime: String?
    ) -> TelegramMediaKind {
        switch kind {
        case .photo:
            return .photo
        case .video:
            return isGIF(name: name, url: url, mime: mime) ? .animation : .video
        case .file:
            return isGIF(name: name, url: url, mime: mime) ? .animation : .document
        }
    }
}

/// Media fields extracted from a Telegram `message` update. `animation` is
/// checked before `document` because Telegram puts both objects in a GIF update.
/// Voice recordings and round video notes have their own Bot API fields; both
/// are checked before `document` so a voice/video-note update can never be
/// misread as an ordinary document or silently skipped.
struct TelegramIncomingMedia {
    enum Kind { case photo, animation, video, voice, videoNote, document }

    let kind: Kind
    let fileID: String
    let fileName: String
    let mimeType: String
    let byteCount: Int?

    var maxKind: MaxMediaKind {
        switch kind {
        case .photo: return .photo
        case .animation:
            return mimeType.lowercased().contains("gif") ? .file : .video
        case .video:
            return mimeType.lowercased().contains("gif") ? .file : .video
        // MAX's native voice/circle attach semantics are not verified for the
        // web client, so the playable bytes are relayed through the proven FILE
        // (Opus/Ogg) and ordinary VIDEO (MP4) upload paths. This is a deliberate
        // fallback: it does not claim a native voice bubble or a round circle.
        case .voice: return .file
        case .videoNote: return .video
        case .document: return .file
        }
    }

    static func parse(_ message: [String: Any]) -> TelegramIncomingMedia? {
        if let animation = message["animation"] as? [String: Any],
           let id = animation["file_id"] as? String, !id.isEmpty {
            return make(kind: .animation, object: animation,
                        fallbackName: "animation.mp4", fallbackMime: "video/mp4", id: id)
        }
        if let video = message["video"] as? [String: Any],
           let id = video["file_id"] as? String, !id.isEmpty {
            return make(kind: .video, object: video,
                        fallbackName: "video.mp4", fallbackMime: "video/mp4", id: id)
        }
        // Telegram voice notes are Opus/Ogg and normally carry no file_name or
        // mime_type. The fallback name gives the MAX upload a correct MIME hint.
        if let voice = message["voice"] as? [String: Any],
           let id = voice["file_id"] as? String, !id.isEmpty {
            return make(kind: .voice, object: voice,
                        fallbackName: "voice.ogg", fallbackMime: "audio/ogg", id: id)
        }
        // Round video notes are MP4 with no file_name in the Bot API.
        if let videoNote = message["video_note"] as? [String: Any],
           let id = videoNote["file_id"] as? String, !id.isEmpty {
            return make(kind: .videoNote, object: videoNote,
                        fallbackName: "video_note.mp4", fallbackMime: "video/mp4", id: id)
        }
        if let document = message["document"] as? [String: Any],
           let id = document["file_id"] as? String, !id.isEmpty {
            return make(kind: .document, object: document,
                        fallbackName: "document", fallbackMime: "application/octet-stream", id: id)
        }
        if let photos = message["photo"] as? [[String: Any]],
           let photo = photos.last,
           let id = photo["file_id"] as? String, !id.isEmpty {
            return make(kind: .photo, object: photo,
                        fallbackName: "photo.jpg", fallbackMime: "image/jpeg", id: id)
        }
        return nil
    }

    private static func make(
        kind: Kind,
        object: [String: Any],
        fallbackName: String,
        fallbackMime: String,
        id: String
    ) -> TelegramIncomingMedia {
        let name = (object["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackName
        let mime = (object["mime_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? MediaInfo.mimeType(fileName: name)
        let size = (object["file_size"] as? NSNumber)?.intValue
        return TelegramIncomingMedia(
            kind: kind,
            fileID: id,
            fileName: name,
            mimeType: mime.isEmpty ? fallbackMime : mime,
            byteCount: size
        )
    }
}
