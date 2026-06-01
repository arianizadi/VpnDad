import Foundation
import Darwin
import NetworkExtension

#if canImport(HevSocks5Tunnel)
import HevSocks5Tunnel
#endif

struct HevRunnerSnapshot {
    var tunnelUploadPackets: UInt64
    var tunnelUploadBytes: UInt64
    var tunnelDownloadPackets: UInt64
    var tunnelDownloadBytes: UInt64
    var bridgeInputPackets: UInt64
    var bridgeInputBytes: UInt64
    var bridgeOutputPackets: UInt64
    var bridgeOutputBytes: UInt64
    var bridgeReadErrors: UInt64
    var bridgeWriteErrors: UInt64
    var bridgeShortWrites: UInt64
    var lastBridgeError: String?
}

final class HevSocks5TunnelRunner {
    private(set) var isRunning = false
    private var worker: Thread?
    private var packetOutputWorker: Thread?
    private var hevFileDescriptor: Int32 = -1
    private var packetFlowFileDescriptor: Int32 = -1
    private let packetInputQueue = DispatchQueue(label: "VpnDad.HevPacketInput")
    private let countersLock = NSLock()
    private var bridgeInputPackets: UInt64 = 0
    private var bridgeInputBytes: UInt64 = 0
    private var bridgeOutputPackets: UInt64 = 0
    private var bridgeOutputBytes: UInt64 = 0
    private var bridgeReadErrors: UInt64 = 0
    private var bridgeWriteErrors: UInt64 = 0
    private var bridgeShortWrites: UInt64 = 0
    private var lastBridgeError: String?

    func start(
        socksAddress: String,
        packetFlow: NEPacketTunnelFlow,
        log: @escaping (String) -> Void
    ) throws {
        #if canImport(HevSocks5Tunnel)
        let bridge = try makePacketFlowBridge(log: log)
        hevFileDescriptor = bridge.hevFileDescriptor
        packetFlowFileDescriptor = bridge.packetFlowFileDescriptor

        let configURL = try writeConfig(socksAddress: socksAddress)
        isRunning = true

        startPacketFlowInputPump(packetFlow: packetFlow, fd: packetFlowFileDescriptor, log: log)
        startPacketFlowOutputPump(packetFlow: packetFlow, fd: packetFlowFileDescriptor, log: log)

        worker = Thread {
            let result = configURL.path.withCString { path in
                hev_socks5_tunnel_main_from_file(path, bridge.hevFileDescriptor)
            }
            if result != 0 {
                log("HevSocks5Tunnel exited with code \(result)")
            }
            self.closeFileDescriptor(&self.hevFileDescriptor)
        }
        worker?.name = "HevSocks5Tunnel"
        worker?.start()
        log("HevSocks5Tunnel started with SOCKS \(socksAddress)")
        #else
        throw TunnelRuntimeError.missingHevSocks5Tunnel
        #endif
    }

    func stop() {
        #if canImport(HevSocks5Tunnel)
        if isRunning {
            hev_socks5_tunnel_quit()
        }
        #endif
        isRunning = false
        closeFileDescriptor(&packetFlowFileDescriptor)
        closeFileDescriptor(&hevFileDescriptor)
        worker = nil
        packetOutputWorker = nil
    }

    func snapshot() -> HevRunnerSnapshot {
        countersLock.lock()
        let inputPackets = bridgeInputPackets
        let inputBytes = bridgeInputBytes
        let outputPackets = bridgeOutputPackets
        let outputBytes = bridgeOutputBytes
        let readErrors = bridgeReadErrors
        let writeErrors = bridgeWriteErrors
        let shortWrites = bridgeShortWrites
        let bridgeError = lastBridgeError
        countersLock.unlock()

        #if canImport(HevSocks5Tunnel)
        var tunnelUploadPackets = 0
        var tunnelUploadBytes = 0
        var tunnelDownloadPackets = 0
        var tunnelDownloadBytes = 0
        hev_socks5_tunnel_stats(
            &tunnelUploadPackets,
            &tunnelUploadBytes,
            &tunnelDownloadPackets,
            &tunnelDownloadBytes
        )
        return HevRunnerSnapshot(
            tunnelUploadPackets: UInt64(max(tunnelUploadPackets, 0)),
            tunnelUploadBytes: UInt64(max(tunnelUploadBytes, 0)),
            tunnelDownloadPackets: UInt64(max(tunnelDownloadPackets, 0)),
            tunnelDownloadBytes: UInt64(max(tunnelDownloadBytes, 0)),
            bridgeInputPackets: inputPackets,
            bridgeInputBytes: inputBytes,
            bridgeOutputPackets: outputPackets,
            bridgeOutputBytes: outputBytes,
            bridgeReadErrors: readErrors,
            bridgeWriteErrors: writeErrors,
            bridgeShortWrites: shortWrites,
            lastBridgeError: bridgeError
        )
        #else
        return HevRunnerSnapshot(
            tunnelUploadPackets: 0,
            tunnelUploadBytes: 0,
            tunnelDownloadPackets: 0,
            tunnelDownloadBytes: 0,
            bridgeInputPackets: inputPackets,
            bridgeInputBytes: inputBytes,
            bridgeOutputPackets: outputPackets,
            bridgeOutputBytes: outputBytes,
            bridgeReadErrors: readErrors,
            bridgeWriteErrors: writeErrors,
            bridgeShortWrites: shortWrites,
            lastBridgeError: bridgeError
        )
        #endif
    }

    #if canImport(HevSocks5Tunnel)
    private func writeConfig(socksAddress: String) throws -> URL {
        let (host, port) = parseHostPort(socksAddress)
        let config = """
        tunnel:
          mtu: 1280
          multi-queue: false
          ipv4: \(AppConstants.tunnelIPv4Address)
          ipv6: '\(AppConstants.tunnelIPv6Address)'
        socks5:
          port: \(port)
          address: \(host)
          udp: 'tcp'
        mapdns:
          address: \(AppConstants.fakeDNSAddress)
          port: 53
          network: 100.64.0.0
          netmask: 255.192.0.0
          cache-size: 10000
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 1200
          log-level: warn
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VpnDadTunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hev.yml", isDirectory: false)
        try Data(config.utf8).write(to: url, options: .atomic)
        return url
    }

    private func makePacketFlowBridge(log: (String) -> Void) throws -> (
        hevFileDescriptor: Int32,
        packetFlowFileDescriptor: Int32
    ) {
        var fileDescriptors = [Int32](repeating: -1, count: 2)
        let result = socketpair(AF_UNIX, SOCK_DGRAM, 0, &fileDescriptors)
        guard result == 0 else {
            throw TunnelRuntimeError.hevIntegrationNotConfigured("socketpair failed: \(currentPOSIXError())")
        }
        log("HevSocks5Tunnel packet-flow bridge created with socketpair")
        return (fileDescriptors[0], fileDescriptors[1])
    }

    private func startPacketFlowInputPump(
        packetFlow: NEPacketTunnelFlow,
        fd: Int32,
        log: @escaping (String) -> Void
    ) {
        packetFlow.readPackets { [weak self, weak packetFlow] packets, _ in
            guard let self, let packetFlow, self.isRunning else {
                return
            }

            self.packetInputQueue.async { [weak self] in
                guard let self, self.isRunning else {
                    return
                }
                for packet in packets {
                    self.writePacketToBridge(packet, fd: fd, log: log)
                }
                self.startPacketFlowInputPump(packetFlow: packetFlow, fd: fd, log: log)
            }
        }
    }

    private func startPacketFlowOutputPump(
        packetFlow: NEPacketTunnelFlow,
        fd: Int32,
        log: @escaping (String) -> Void
    ) {
        packetOutputWorker = Thread { [weak self, weak packetFlow] in
            guard let self, let packetFlow else {
                return
            }

            var buffer = [UInt8](repeating: 0, count: 65535)
            while self.isRunning {
                let count = buffer.withUnsafeMutableBytes { pointer in
                    Darwin.read(fd, pointer.baseAddress, pointer.count)
                }

                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if self.isRunning {
                        let error = self.currentPOSIXError()
                        self.recordBridgeReadError(error)
                        log("HevSocks5Tunnel packet-flow bridge read failed: \(error)")
                    }
                    break
                }

                guard count > MemoryLayout<UInt32>.size else {
                    continue
                }

                let packetBytes = buffer[MemoryLayout<UInt32>.size..<count]
                let packet = Data(packetBytes)
                let packetProtocol = NSNumber(value: self.packetProtocol(for: packet))
                packetFlow.writePackets([packet], withProtocols: [packetProtocol])
                self.recordBridgeOutput(byteCount: UInt64(packet.count))
            }
        }
        packetOutputWorker?.name = "HevSocks5TunnelPacketFlowOutput"
        packetOutputWorker?.start()
    }

    private func writePacketToBridge(_ packet: Data, fd: Int32, log: (String) -> Void) {
        guard !packet.isEmpty else {
            return
        }

        var header = UInt32(bitPattern: packetProtocol(for: packet)).bigEndian
        let writeResult = packet.withUnsafeBytes { packetBuffer in
            withUnsafeMutablePointer(to: &header) { headerPointer in
                var vectors = [
                    iovec(iov_base: headerPointer, iov_len: MemoryLayout<UInt32>.size),
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: packetBuffer.baseAddress), iov_len: packet.count)
                ]
                return Darwin.writev(fd, &vectors, Int32(vectors.count))
            }
        }

        let expectedBytes = packet.count + MemoryLayout<UInt32>.size
        if writeResult == expectedBytes {
            recordBridgeInput(byteCount: UInt64(packet.count))
        } else if writeResult < 0, isRunning {
            let error = currentPOSIXError()
            recordBridgeWriteError(error)
            log("HevSocks5Tunnel packet-flow bridge write failed: \(error)")
        } else if isRunning {
            let error = "short write \(writeResult)/\(expectedBytes)"
            recordBridgeShortWrite(error)
            log("HevSocks5Tunnel packet-flow bridge short write: \(error)")
        }
    }

    private func recordBridgeInput(byteCount: UInt64) {
        countersLock.lock()
        bridgeInputPackets += 1
        bridgeInputBytes += byteCount
        countersLock.unlock()
    }

    private func recordBridgeOutput(byteCount: UInt64) {
        countersLock.lock()
        bridgeOutputPackets += 1
        bridgeOutputBytes += byteCount
        countersLock.unlock()
    }

    private func recordBridgeReadError(_ error: String) {
        countersLock.lock()
        bridgeReadErrors += 1
        lastBridgeError = error
        countersLock.unlock()
    }

    private func recordBridgeWriteError(_ error: String) {
        countersLock.lock()
        bridgeWriteErrors += 1
        lastBridgeError = error
        countersLock.unlock()
    }

    private func recordBridgeShortWrite(_ error: String) {
        countersLock.lock()
        bridgeShortWrites += 1
        lastBridgeError = error
        countersLock.unlock()
    }

    private func packetProtocol(for packet: Data) -> Int32 {
        guard let firstByte = packet.first else {
            return AF_INET
        }
        return (firstByte >> 4) == 6 ? AF_INET6 : AF_INET
    }

    private func closeFileDescriptor(_ fd: inout Int32) {
        guard fd >= 0 else {
            return
        }
        close(fd)
        fd = -1
    }

    private func currentPOSIXError() -> String {
        String(cString: strerror(errno))
    }

    private func parseHostPort(_ address: String) -> (String, Int) {
        let parts = address.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let port = Int(parts[1]) {
            return (parts[0], port)
        }
        return ("127.0.0.1", 18080)
    }
    #endif
}
