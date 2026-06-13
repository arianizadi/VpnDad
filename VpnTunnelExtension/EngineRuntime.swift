import Foundation

#if canImport(EngineBridge)
import EngineBridge
#endif

final class EngineRuntime {
    private var logSink: AnyObject?
    private var packetSink: AnyObject?

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

    func startPacket(
        profileJSON: String,
        packet: @escaping (Data) -> Void,
        log: @escaping (String) -> Void
    ) throws {
        #if canImport(EngineBridge)
        let logSink = EngineBridgeLogSink(log: log)
        let packetSink = EngineBridgePacketSink(write: packet)
        self.logSink = logSink
        self.packetSink = packetSink
        var error: NSError?
        MobilebridgeStartPacketEngine(profileJSON, packetSink, logSink, &error)
        if let error {
            throw error
        }
        #else
        throw TunnelRuntimeError.missingEngineBridge
        #endif
    }

    func writePacket(_ packet: Data) throws {
        #if canImport(EngineBridge)
        var error: NSError?
        MobilebridgeWritePacket(packet, &error)
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
        packetSink = nil
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

final class EngineBridgePacketSink: NSObject, MobilebridgePacketCallbackProtocol {
    private let write: (Data) -> Void

    init(write: @escaping (Data) -> Void) {
        self.write = write
    }

    func writePacket(_ packet: Data?) {
        guard let packet else { return }
        write(packet)
    }
}
#endif
