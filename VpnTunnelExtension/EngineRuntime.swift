import Foundation

#if canImport(EngineBridge)
import EngineBridge
#endif

final class EngineRuntime {
    private var logSink: AnyObject?

    func start(profileJSON: String, socksAddress: String, log: @escaping (String) -> Void) throws {
        #if canImport(EngineBridge)
        let sink = EngineBridgeLogSink(log: log)
        logSink = sink
        var error: NSError?
        MobilebridgeStartEngine(profileJSON, socksAddress, sink, &error)
        if let error {
            throw error
        }
        #else
        throw TunnelRuntimeError.missingEngineBridge
        #endif
    }

    func stop() {
        #if canImport(EngineBridge)
        var error: NSError?
        MobilebridgeStopEngine(&error)
        #endif
        logSink = nil
    }

    func statusJSON() -> String {
        #if canImport(EngineBridge)
        return MobilebridgeEngineStatus()
        #else
        return #"{"running":false,"lastError":"EngineBridge.xcframework is not embedded"}"#
        #endif
    }
}

#if canImport(EngineBridge)
final class EngineBridgeLogSink: NSObject, MobilebridgeLogCallbackProtocol {
    private let emit: (String) -> Void

    init(log: @escaping (String) -> Void) {
        emit = log
    }

    func log(_ line: String?) {
        guard let line else { return }
        emit(line)
    }
}
#endif
