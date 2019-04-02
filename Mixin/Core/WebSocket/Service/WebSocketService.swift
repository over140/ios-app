import Foundation
import SocketRocket
import DataCompression
import Bugsnag
import Alamofire

class WebSocketService: NSObject {

    static let shared = WebSocketService()

    private let exitCode = 9999
    private let failCode = 9998
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    private(set) var client: SRWebSocket?
    private(set) var connected = false

    private var transactions = [String: SendJobTransaction]()
    private var recoverJobs = false
    private let websocketDispatchQueue = DispatchQueue(label: "one.mixin.messenger.queue.websocket")
    private let sendDispatchQueue = DispatchQueue(label: "one.mixin.messenger.queue.websocket.send")

    private var reconnectWorkItem: DispatchWorkItem?
    private var timer: Timer?
    private var sentPingCount = 0
    private var receivedPongCount = 0
    private var awaitingPong: Bool = false
    private var pingInterval: TimeInterval = 15
    private var requestHeaderTime: TimeInterval = 0
    private var lastConnectTime: TimeInterval = 0
    private var lastNetworkReachabled = true
    
    func connect() {
        guard client == nil else {
            return
        }
        lastNetworkReachabled = NetworkManager.shared.isReachable
        lastConnectTime = Date().timeIntervalSince1970
        client = instanceWebSocket()
        client?.setDelegateDispatchQueue(websocketDispatchQueue)
        client?.delegate = self
        client?.open()
    }

    func disconnect() {
        connected = false
        tearDown()
        client?.delegate = nil
        client?.close(withCode: exitCode, reason: "disconnect")
        client = nil
        removeAllJob()
        reconnectWorkItem?.cancel()
        transactions.removeAll()
    }

    deinit {
        removeAllJob()
        transactions.removeAll()
        reconnectWorkItem?.cancel()
        client?.delegate = nil
        client?.close()
    }
}

extension WebSocketService {

    @discardableResult
    func sendData(message: BlazeMessage) -> Bool {
        guard let websocket = self.client, websocket.readyState == .OPEN else {
            return false
        }
        guard let jsonData = try? jsonEncoder.encode(message), let gzipped = jsonData.gzip() else {
            return false
        }

        websocket.send(gzipped)
        return true
    }
}

extension WebSocketService: SRWebSocketDelegate {

    func webSocket(_ webSocket: SRWebSocket!, didReceiveMessage message: Any!) {
        guard let data = message as? Data, let json = data.gunzip() else {
            return
        }
        guard let blazeMessage = (try? jsonDecoder.decode(BlazeMessage.self, from: json)) else {
            UIApplication.trackError("WebSocketService", action: "didReceiveMessage", userInfo: ["data": String(data: json, encoding: .utf8) ?? ""])
            return
        }

        if let error = blazeMessage.error {
            if let transaction = transactions[blazeMessage.id] {
                transactions.removeValue(forKey: blazeMessage.id)
                transaction.callback(.failure(error))
            }
            if blazeMessage.action == BlazeMessageAction.error.rawValue && error.code == 401 {
                if !AccountUserDefault.shared.hasClockSkew {
                    AccountAPI.shared.logout()
                }
            }
        } else {
            if let transaction = transactions[blazeMessage.id] {
                transactions.removeValue(forKey: blazeMessage.id)
                transaction.callback(.success(blazeMessage))
            }

            if blazeMessage.data != nil {
                if blazeMessage.isReceiveMessageAction() {
                    ReceiveMessageService.shared.receiveMessage(blazeMessage: blazeMessage, rawData: json)
                } else {
                    guard let data = blazeMessage.toBlazeMessageData() else {
                        return
                    }
                    SendMessageService.shared.sendAckMessage(messageId: data.messageId, status: .READ)
                }
            }
        }
    }

    func webSocketRequestHeaders(_ request: URLRequest!) -> [String : String]! {
        FileManager.default.writeLog(log: "WebSocketService...webSocketWillOpen")
        requestHeaderTime = Date().timeIntervalSince1970
        return MixinRequest.getHeaders(request: request)
    }

    func webSocketDidOpen(_ webSocket: SRWebSocket!) {
        guard client != nil else {
            return
        }
        if let responseServerTime = CFHTTPMessageCopyHeaderFieldValue(webSocket.receivedHTTPHeaders, "x-server-time" as CFString)?.takeRetainedValue() as String?, let serverTime = Double(responseServerTime), serverTime > 0 {
            let clientTime = Date().timeIntervalSince1970
            if abs(serverTime / 1000000000 - clientTime) > 300 {
                FileManager.default.writeLog(log: "WebSocketService...webSocketDidOpen...clock skew...serverTime:\(serverTime / 1000000000)...clientTime:\(clientTime)...requestHeaderTime:\(requestHeaderTime)")
                if clientTime - requestHeaderTime > 60 {
                    WebSocketService.shared.reconnect(didClose: false)
                } else {
                    AccountUserDefault.shared.hasClockSkew = true
                    DispatchQueue.main.async {
                        WebSocketService.shared.disconnect()
                        AppDelegate.current.window?.rootViewController = makeInitialViewController()
                    }
                }
                return
            }
        }

        FileManager.default.writeLog(log: "WebSocketService...webSocketDidOpen")
        connected = true
        NotificationCenter.default.postOnMain(name: .SocketStatusChanged, object: true)

        ReceiveMessageService.shared.processReceiveMessages()
        sendPendingMessage()
        resumeAllJob()
        ConcurrentJobQueue.shared.addJob(job: RefreshOffsetJob())
        pingRunnable()

        if CommonUserDefault.shared.backupCategory != .off {
            BackupJobQueue.shared.addJob(job: BackupJob())
        }
    }

    func webSocket(_ webSocket: SRWebSocket!, didFailWithError error: Error!) {
        #if DEBUG
        print("======WebSocketService...didFailWithError...error:\(String(describing: error))")
        #endif
        reconnect(didClose: false)
    }

    func webSocket(_ webSocket: SRWebSocket!, didCloseWithCode code: Int, reason: String!, wasClean: Bool) {
        #if DEBUG
        print("======WebSocketService...didCloseWithCode...code:\(code)...reason:\(String(describing: reason))")
        #endif
        guard code != exitCode && code != failCode else {
            return
        }

        reconnect(didClose: true)
    }

    func webSocket(_ webSocket: SRWebSocket!, didReceivePong pongPayload: Data!) {
        receivedPongCount += 1
        awaitingPong = false
    }

    func pingRunnable() {
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(timeInterval: self.pingInterval, target: self, selector: #selector(self.writePingFrame), userInfo: nil, repeats: true)
            self.timer?.fire()
        }
    }

    func tearDown() {
        awaitingPong = false
        sentPingCount = 0
        receivedPongCount = 0
        timer?.invalidate()
        timer = nil
    }

    @objc func writePingFrame() {
        let failedPing = awaitingPong ? sentPingCount : -1
        sentPingCount += 1
        awaitingPong = true
        if failedPing != -1 {
            #if DEBUG
            print("sent ping but didn't receive pong within \(pingInterval)s after \(failedPing - 1) successful ping/pongs")
            #endif
            reconnect(didClose: false)
            return
        }
        if let client = client, client.readyState == .OPEN {
            client.sendPing(Data())
        }
    }

    private func cancelTransactions() {
        let ids = transactions.keys
        for transactionId in ids {
            let transaction = transactions[transactionId]
            transaction?.callback(.failure(APIError.createTimeoutError()))
            transactions.removeValue(forKey: transactionId)
        }
    }

    func reconnect(didClose: Bool) {
        FileManager.default.writeLog(log: "WebSocketService...reconnect")
        connected = false
        NotificationCenter.default.postOnMain(name: .SocketStatusChanged, object: false)
        ReceiveMessageService.shared.refreshRefreshOneTimePreKeys = [String: TimeInterval]()
        cancelTransactions()
        suspendAllJob()
        tearDown()
        client?.delegate = nil
        if !didClose {
            client?.close(withCode: failCode, reason: "OK")
        }
        client = nil
        reconnectWorkItem?.cancel()


        if AccountAPI.shared.didLogin && NetworkManager.shared.isReachable && (!lastNetworkReachabled || Date().timeIntervalSince1970 - lastConnectTime >= 1) {
            WebSocketService.shared.connect()
        } else {
            let reconnectWorkItem = DispatchWorkItem(block: {
                guard AccountAPI.shared.didLogin, let reconnectWorkItem = WebSocketService.shared.reconnectWorkItem, !reconnectWorkItem.isCancelled else {
                    return
                }
                WebSocketService.shared.connect()
            })
            self.reconnectWorkItem = reconnectWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reconnectWorkItem)
        }
    }

    func checkConnectStatus() {
        guard AccountAPI.shared.didLogin, NetworkManager.shared.isReachable, WebSocketService.shared.connected, client?.readyState != .OPEN else {
            return
        }
        reconnect(didClose: false)
    }

    func webSocketShouldConvertTextFrame(toString webSocket: SRWebSocket!) -> Bool {
        return false
    }

    private func instanceWebSocket() -> SRWebSocket {
        var request = URLRequest(url: URL(string: "wss://blaze.mixin.one")!)
        request.timeoutInterval = 5
        return SRWebSocket(urlRequest: request)
    }
}


extension WebSocketService {

    func resumeAllJob() {
        ConcurrentJobQueue.shared.resume()
    }

    func suspendAllJob() {
        ConcurrentJobQueue.shared.suspend()
    }

    func removeAllJob() {
        recoverJobs = false
        ConcurrentJobQueue.shared.cancelAllOperations()
    }

    func lanuchInit() {
        ConcurrentJobQueue.shared.addJob(job: RefreshAssetsJob())
        let cur = Date().timeIntervalSince1970
        let last = CryptoUserDefault.shared.rotateSignedPrekey
        if last < 1 {
            CryptoUserDefault.shared.rotateSignedPrekey = cur
        } else if cur - last > 60 * 60 * 24 * 2 {
            ConcurrentJobQueue.shared.addJob(job: RotateSignedPreKeyJob())
            CryptoUserDefault.shared.rotateSignedPrekey = cur
        }
    }

    func sendPendingMessage() {
        let message = BlazeMessage(action: BlazeMessageAction.listPendingMessages.rawValue)
        let transaction = SendJobTransaction(callback: { (result) in
            guard result.isSuccess else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: {
                    guard WebSocketService.shared.connected else {
                        return
                    }
                    WebSocketService.shared.sendPendingMessage()
                })
                return
            }

            if !WebSocketService.shared.recoverJobs {
                WebSocketService.shared.recoverJobs = true

                SendMessageService.shared.restoreJobs()
                ConcurrentJobQueue.shared.restoreJobs()

                WebSocketService.shared.lanuchInit()
            }
        })
        transactions[message.id] = transaction
        sendData(message: message)
    }

    func syncSendMessage(blazeMessage: BlazeMessage) throws -> BlazeMessage? {
        return try sendDispatchQueue.sync {
            guard AccountAPI.shared.didLogin else {
                return nil
            }
            var result: BlazeMessage?
            var err = APIError.createTimeoutError()

            let semaphore = DispatchSemaphore(value: 0)
            let transaction = SendJobTransaction(callback: { (jobResult) in
                switch jobResult {
                case let .success(blazeMessage):
                    result = blazeMessage
                case let .failure(error):
                    if error.code == 10002 {
                        if let param = blazeMessage.params, let messageId = param.messageId, messageId != messageId.lowercased() {
                            MessageDAO.shared.deleteMessage(id: messageId)
                            JobDAO.shared.removeJob(jobId: blazeMessage.id)
                        }
                    }
                    err = error
                }
                semaphore.signal()
            })
            transactions[blazeMessage.id] = transaction
            if !sendData(message: blazeMessage) {
                transactions.removeValue(forKey: blazeMessage.id)
                throw err
            }
            _ = semaphore.wait(timeout: .now() + .seconds(5))

            guard let blazeMessage = result else {
                throw err
            }
            return blazeMessage
        }
    }

}

private struct SendJobTransaction {

    let callback: (APIResult<BlazeMessage>) -> Void

}
