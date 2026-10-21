import Foundation
import UIKit
import AVFoundation
import ImageIO

enum MediaCategory: String, Codable {
    case chatBit = "chat_bit"
    case chatBitThumbnail = "chat_bit_thumbnail"
    case chatVoice = "chat_voice"
    case chatFile = "chat_file"
    case chatMedia = "chat_media"
    case chatEncrypted = "chat_encrypted"
}

private struct PresignRequestBody: Encodable {
    var category: MediaCategory
    var fileExtension: String
    var contentType: String

    enum CodingKeys: String, CodingKey {
        case category
        case fileExtension = "file_extension"
        case contentType = "content_type"
    }
}

private struct PresignResponseBody: Decodable {
    var uploadUrl: String
    var publicUrl: String
    var key: String
    var expiresInSeconds: Int
    var requiredContentType: String

    enum CodingKeys: String, CodingKey {
        case uploadUrl = "upload_url"
        case publicUrl = "public_url"
        case key
        case expiresInSeconds = "expires_in_seconds"
        case requiredContentType = "required_content_type"
    }
}

enum ChatMediaUploadError: Error, LocalizedError {
    case encodingFailed
    case uploadFailed(statusCode: Int, body: String? = nil)
    case missingFile

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Couldn't prepare the file for upload"
        case .missingFile: return "No file to upload"
        case .uploadFailed(let statusCode, let body):
            if let body, !body.isEmpty {
                return "Upload failed (\(statusCode)): \(body)"
            }
            return "Upload failed (\(statusCode))"
        }
    }
}

final class ChatMediaUploader {
    static let shared = ChatMediaUploader()
    private init() {}

    typealias ProgressHandler = (Double) -> Void

    func encrypted(_ op: () async throws -> SendMessageRequestBody) async throws -> SendMessageRequestBody {
        let capture = E2EEUploadCapture()
        var body = try await E2EEUploadContext.$capture.withValue(capture) { try await op() }
        guard let att = E2EEMedia.makeAttachment(from: body, blobs: capture.blobs) else {
            throw ChatMediaUploadError.encodingFailed
        }
        body.e2eeAttachment = att
        return body
    }

    func uploadForConversation(
        _ conversationId: String, _ op: () async throws -> SendMessageRequestBody
    ) async throws -> SendMessageRequestBody {
        if await E2EEService.shared.shouldEncrypt(conversationId: conversationId) {
            return try await encrypted(op)
        }
        return try await op()
    }

    private func encryptAndUpload(
        fileURL: URL, contentType: String, isFile: Bool, capture: E2EEUploadCapture, onProgress: ProgressHandler?
    ) async throws -> String {
        let blobURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bin")
        defer { try? FileManager.default.removeItem(at: blobURL) }
        let sealed = try await Task.detached(priority: .userInitiated) {
            try E2EEAttachmentCrypto.encryptFile(at: fileURL, to: blobURL)
        }.value

        let presignResponse: ChatApiResponse<PresignResponseBody> = try await NetworkService.shared.post(
            endpoint: "/media/presign",
            body: PresignRequestBody(category: .chatEncrypted, fileExtension: "bin", contentType: "application/octet-stream")
        )
        guard presignResponse.success, let presign = presignResponse.data,
              let uploadURL = URL(string: presign.uploadUrl) else {
            throw ChatMediaUploadError.uploadFailed(statusCode: 0, body: presignResponse.error)
        }
        try await putFile(blobURL, to: uploadURL, contentType: presign.requiredContentType, onProgress: onProgress)

        let ref = E2EEBlobRef(url: presign.publicUrl, key: sealed.key.base64EncodedString(),
                              digest: sealed.digest.base64EncodedString(), size: sealed.plainSize, mime: contentType)
        let name: String? = isFile ? fileURL.lastPathComponent : nil
        let local = E2EEMedia.localURL(for: ref, name: name)
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.copyItem(at: fileURL, to: local)
        capture.append(ref, name: name)
        return local.absoluteString
    }

    func uploadBit(_ bit: CapturedBit, onProgress: ProgressHandler? = nil) async throws -> SendMessageRequestBody {
        if let image = bit.finalImage {
            return try await uploadImageBit(image, viewDurationSeconds: bit.viewDurationSeconds, onProgress: onProgress)
        } else if let videoURL = bit.videoURL {
            return try await uploadVideoBit(videoURL, viewDurationSeconds: bit.viewDurationSeconds, onProgress: onProgress)
        }
        throw ChatMediaUploadError.missingFile
    }

    func uploadVoiceMessage(fileURL: URL, durationMs: Int64, onProgress: ProgressHandler? = nil) async throws -> SendMessageRequestBody {
        let publicUrl = try await presignAndUpload(
            fileURL: fileURL,
            category: .chatVoice,
            fileExtension: fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension,
            contentType: "audio/m4a",
            onProgress: onProgress
        )
        let metadata = MessageMediaMetadata(
            durationMs: durationMs, fileSizeBytes: try? fileSize(of: fileURL),
            mimeType: "audio/m4a", thumbnailUrl: nil, width: nil, height: nil, lat: nil, lng: nil, isLiveLocation: nil
        )
        return SendMessageRequestBody(contentType: .voice, textContent: nil, mediaUrl: publicUrl, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: nil)
    }

    func uploadImage(_ image: UIImage, onProgress: ProgressHandler? = nil) async throws -> SendMessageRequestBody {
        guard let prepared = ChatImageResizer.prepareForUpload(image) else { throw ChatMediaUploadError.encodingFailed }
        let ext = prepared.contentType == "image/heic" ? "heic" : "jpg"
        let tempURL = try writeTemp(prepared.data, ext: ext)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let publicUrl = try await presignAndUpload(
            fileURL: tempURL, category: .chatMedia, fileExtension: ext, contentType: prepared.contentType, onProgress: onProgress
        )

        let dimensions = pixelDimensions(of: prepared.data)
        let metadata = MessageMediaMetadata(
            durationMs: nil, fileSizeBytes: Int64(prepared.data.count), mimeType: prepared.contentType,
            thumbnailUrl: nil, width: dimensions?.width, height: dimensions?.height,
            lat: nil, lng: nil, isLiveLocation: nil
        )
        return SendMessageRequestBody(contentType: .image, textContent: nil, mediaUrl: publicUrl, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: false)
    }

    func uploadVideo(fileURL videoURL: URL, onProgress: ProgressHandler? = nil) async throws -> SendMessageRequestBody {
        let prepared = try await ChatMediaEncoder.prepareVideoForUpload(sourceURL: videoURL)
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }
        let asset = AVURLAsset(url: prepared.fileURL)

        let durationSeconds = try await asset.load(.duration).seconds
        let durationMs = Int64((durationSeconds.isFinite ? durationSeconds : 0) * 1000)

        let publicUrl = try await presignAndUpload(
            fileURL: prepared.fileURL, category: .chatMedia, fileExtension: "mp4", contentType: "video/mp4", onProgress: onProgress
        )

        var thumbnailUrl: String?
        if let thumbnailImage = try? await generateThumbnail(from: asset),
           let thumbData = thumbnailImage.jpegData(compressionQuality: 0.7) {
            let thumbTemp = try writeTemp(thumbData, ext: "jpg")
            defer { try? FileManager.default.removeItem(at: thumbTemp) }
            thumbnailUrl = try? await presignAndUpload(
                fileURL: thumbTemp, category: .chatMedia, fileExtension: "jpg", contentType: "image/jpeg", onProgress: nil
            )
        }

        let metadata = MessageMediaMetadata(
            durationMs: durationMs, fileSizeBytes: try? fileSize(of: prepared.fileURL), mimeType: "video/mp4",
            thumbnailUrl: thumbnailUrl, width: prepared.width, height: prepared.height, lat: nil, lng: nil, isLiveLocation: nil
        )
        return SendMessageRequestBody(contentType: .video, textContent: nil, mediaUrl: publicUrl, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: false)
    }

    func uploadFile(fileURL: URL, mimeType: String, onProgress: ProgressHandler? = nil) async throws -> SendMessageRequestBody {
        let ext = fileURL.pathExtension.isEmpty ? "dat" : fileURL.pathExtension
        let publicUrl = try await presignAndUpload(fileURL: fileURL, category: .chatFile, fileExtension: ext, contentType: mimeType, onProgress: onProgress)
        let metadata = MessageMediaMetadata(
            durationMs: nil, fileSizeBytes: try? fileSize(of: fileURL),
            mimeType: mimeType, thumbnailUrl: nil, width: nil, height: nil, lat: nil, lng: nil, isLiveLocation: nil
        )
        return SendMessageRequestBody(contentType: .file, textContent: nil, mediaUrl: publicUrl, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: nil)
    }

    private func uploadImageBit(_ image: UIImage, viewDurationSeconds: Int, onProgress: ProgressHandler?) async throws -> SendMessageRequestBody {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else { throw ChatMediaUploadError.encodingFailed }
        let tempURL = try writeTemp(jpegData, ext: "jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let publicUrl = try await presignAndUpload(
            fileURL: tempURL, category: .chatBit, fileExtension: "jpg", contentType: "image/jpeg", onProgress: onProgress
        )

        let metadata = MessageMediaMetadata(
            durationMs: nil, fileSizeBytes: Int64(jpegData.count), mimeType: "image/jpeg",
            thumbnailUrl: nil, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale),
            lat: nil, lng: nil, isLiveLocation: nil, viewDurationSeconds: viewDurationSeconds
        )

        return SendMessageRequestBody(contentType: .bit, textContent: nil, mediaUrl: publicUrl, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: true)
    }

    private func uploadVideoBit(_ videoURL: URL, viewDurationSeconds: Int, onProgress: ProgressHandler?) async throws -> SendMessageRequestBody {
        let compressedURL = try await BitVideoEncoder.compress(sourceURL: videoURL)
        defer { try? FileManager.default.removeItem(at: compressedURL) }
        let asset = AVURLAsset(url: compressedURL)

        let durationSeconds = try await asset.load(.duration).seconds
        let durationMs = Int64((durationSeconds.isFinite ? durationSeconds : 0) * 1000)

        let publicUrl = try await presignAndUpload(
            fileURL: compressedURL, category: .chatBit, fileExtension: "mp4", contentType: "video/mp4", onProgress: onProgress
        )

        var thumbnailUrl: String?
        if let thumbnailImage = try? await generateThumbnail(from: asset),
           let thumbData = thumbnailImage.jpegData(compressionQuality: 0.7) {
            let thumbTemp = try writeTemp(thumbData, ext: "jpg")
            defer { try? FileManager.default.removeItem(at: thumbTemp) }
            thumbnailUrl = try? await presignAndUpload(
                fileURL: thumbTemp, category: .chatBitThumbnail, fileExtension: "jpg", contentType: "image/jpeg", onProgress: nil
            )
        }

        let metadata = MessageMediaMetadata(
            durationMs: durationMs, fileSizeBytes: try? fileSize(of: compressedURL), mimeType: "video/mp4",
            thumbnailUrl: thumbnailUrl, width: nil, height: nil, lat: nil, lng: nil, isLiveLocation: nil,
            viewDurationSeconds: viewDurationSeconds
        )

        return SendMessageRequestBody(contentType: .bit, textContent: nil, mediaUrl: publicUrl, mediaMetadata: metadata, replyToMessageId: nil, isDisappearing: true)
    }

    private func generateThumbnail(from asset: AVURLAsset) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cgImage = try await generator.image(at: .zero).image
        return UIImage(cgImage: cgImage)
    }

    private func presignAndUpload(
        fileURL: URL, category: MediaCategory, fileExtension: String, contentType: String, onProgress: ProgressHandler?
    ) async throws -> String {
        if let capture = E2EEUploadContext.capture {
            return try await encryptAndUpload(fileURL: fileURL, contentType: contentType, isFile: category == .chatFile, capture: capture, onProgress: onProgress)
        }
        let presignResponse: ChatApiResponse<PresignResponseBody> = try await NetworkService.shared.post(
            endpoint: "/media/presign",
            body: PresignRequestBody(category: category, fileExtension: fileExtension, contentType: contentType)
        )
        guard presignResponse.success, let presign = presignResponse.data,
              let uploadURL = URL(string: presign.uploadUrl) else {
            throw ChatMediaUploadError.uploadFailed(statusCode: 0, body: presignResponse.error)
        }

        try await putFile(fileURL, to: uploadURL, contentType: presign.requiredContentType, onProgress: onProgress)
        return presign.publicUrl
    }

    private func putFile(_ fileURL: URL, to uploadURL: URL, contentType: String, onProgress: ProgressHandler?) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        if let onProgress {
            try await uploadWithProgress(request: request, fileURL: fileURL, onProgress: onProgress)
        } else {
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
            try checkResponse(response, data: data)
        }
    }

    private func uploadWithProgress(request: URLRequest, fileURL: URL, onProgress: @escaping ProgressHandler) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = UploadProgressDelegate(onProgress: onProgress) { result in
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.resume()
        }
    }

    private func checkResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            throw ChatMediaUploadError.uploadFailed(statusCode: code, body: body)
        }
    }

    private func writeTemp(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int64) ?? 0
    }

    private func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let onProgress: (Double) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var didComplete = false
    private var responseData = Data()

    init(onProgress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        if let error {
            completion(.failure(error))
        } else if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: responseData, encoding: .utf8)
            completion(.failure(ChatMediaUploadError.uploadFailed(statusCode: http.statusCode, body: body)))
        } else {
            completion(.success(()))
        }
    }
}
