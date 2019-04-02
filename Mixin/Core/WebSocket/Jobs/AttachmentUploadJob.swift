import Foundation
import UIKit
import Bugsnag

class AttachmentUploadJob: UploadOrDownloadJob {

    internal var attachResponse: AttachmentResponse?
    
    private var stream: InputStream?

    internal var fileUrl: URL? {
        guard let mediaUrl = message.mediaUrl, !mediaUrl.isEmpty else {
            return nil
        }
        return MixinFile.url(ofChatDirectory: .photos, filename: mediaUrl)
    }
    
    init(message: Message) {
        super.init(messageId: message.messageId)
        super.message = message
    }

    class func jobId(messageId: String) -> String {
        return "attachment-upload-\(messageId)"
    }
    
    override func getJobId() -> String {
        return AttachmentUploadJob.jobId(messageId: message.messageId)
    }

    override func execute() -> Bool {
        guard !self.message.messageId.isEmpty else {
            return false
        }
        guard let fileUrl = fileUrl else {
            return false
        }
        repeat {
            switch MessageAPI.shared.requestAttachment() {
            case let .success(attachResponse):
                self.attachResponse = attachResponse
                guard uploadAttachment(attachResponse: attachResponse, fileUrl: fileUrl) else {
                    return false
                }
                return true
            case let .failure(error):
                guard error.isClientError || error.isServerError else {
                    return false
                }
                checkNetworkAndWebSocket()
                Thread.sleep(forTimeInterval: 2)
            }
        } while AccountAPI.shared.didLogin && !isCancelled
        return false
    }

    private func uploadAttachment(attachResponse: AttachmentResponse, fileUrl: URL) -> Bool {
        guard let uploadUrl = attachResponse.uploadUrl, !uploadUrl.isEmpty, var request = try? URLRequest(url: uploadUrl, method: .put) else {
            UIApplication.trackError("AttachmentUploadJob", action: "uploadAttachment upload_url is nil", userInfo: ["uploadUrl": "\(attachResponse.uploadUrl ?? "")"])
            return false
        }

        let contentLength: Int
        if message.category.hasPrefix("SIGNAL_") {
            if let inputStream = AttachmentEncryptingInputStream(url: fileUrl) {
                contentLength = inputStream.contentLength
                stream = inputStream
            } else {
                UIApplication.trackError("AttachmentUploadJob", action: "AttachmentEncryptingInputStream init failed")
                return false
            }
        } else {
            stream = InputStream(url: fileUrl)
            if stream == nil {
                UIApplication.trackError("AttachmentUploadJob", action: "InputStream init failed")
                return false
            } else {
                contentLength = Int(FileManager.default.fileSize(fileUrl.path))
            }
        }
        guard let inputStream = stream, contentLength > 0 else {
            return false
        }
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(contentLength)", forHTTPHeaderField: "Content-Length")
        request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")
        request.setValue("Connection", forHTTPHeaderField: "close")
        request.cachePolicy = .reloadIgnoringCacheData
        request.httpBodyStream = inputStream
        
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.dataTask(with: request, completionHandler: completionHandler)
        task?.resume()
        session.finishTasksAndInvalidate()
        return true
    }

    override func taskFinished() {
        guard let attachResponse = self.attachResponse else {
            return
        }
        let key = (stream as? AttachmentEncryptingInputStream)?.key
        let digest = (stream as? AttachmentEncryptingInputStream)?.digest
        let content = getMediaDataText(attachmentId: attachResponse.attachmentId, key: key, digest: digest)
        message.content = content
        MessageDAO.shared.updateMessageContentAndMediaStatus(content: content, mediaStatus: .DONE, messageId: message.messageId, conversationId: message.conversationId)

        SendMessageService.shared.sendMessage(message: message, data: content)
        SendMessageService.shared.sendSessionMessage(message: message, data: content)
    }

    internal func getMediaDataText(attachmentId: String, key: Data?, digest: Data?) -> String {
        let transferMediaData = TransferAttachmentData(key: key, digest: digest, attachmentId: attachmentId, mimeType: message.mediaMimeType!, width: message.mediaWidth, height: message.mediaHeight, size:message.mediaSize!, thumbnail: message.thumbImage, name: message.name, duration: message.mediaDuration, waveform: message.mediaWaveform)
        return (try? jsonEncoder.encode(transferMediaData).base64EncodedString()) ?? ""
    }
}

extension AttachmentUploadJob: URLSessionTaskDelegate {

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let change = ConversationChange(conversationId: message.conversationId,
                                        action: .updateUploadProgress(messageId: message.messageId, progress: progress))
        NotificationCenter.default.postOnMain(name: .ConversationDidChange, object: change)
    }

}
