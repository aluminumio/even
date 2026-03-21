import CoreBluetooth
import Foundation

// Even UART Service (EUS) — the authenticated protocol that drives the display
private let EUS_SVC = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5450")
private let EUS_TX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5401")
private let EUS_RX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5402")

// Nordic UART Service (NUS) — raw gesture events (0xF5 prefix)
private let NUS_SVC = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let NUS_RX  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

// MARK: - Protobuf helpers

private func varint(_ v: Int) -> Data {
    var v = v; var r = Data()
    while v > 0x7F { r.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
    r.append(UInt8(v & 0x7F))
    return r
}

private func vi(_ field: Int, _ value: Int) -> Data {
    Data([UInt8(field << 3)]) + varint(value)
}

private func ld(_ field: Int, _ data: Data) -> Data {
    Data([UInt8(field << 3 | 2)]) + varint(data.count) + data
}

private func crc16(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for b in data {
        crc ^= UInt16(b) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000 != 0) ? ((crc << 1) ^ 0x1021) : (crc << 1)
        }
    }
    return crc
}

private func packet(_ seq: Int, _ svcHi: UInt8, _ svcLo: UInt8, _ payload: Data) -> Data {
    let hdr = Data([0xAA, 0x21, UInt8(seq), UInt8(payload.count + 2), 0x01, 0x01, svcHi, svcLo])
    let c = crc16(payload)
    return hdr + payload + Data([UInt8(c & 0xFF), UInt8(c >> 8)])
}

// MARK: - Protocol packets

private func authPackets() -> [Data] {
    let ts = varint(Int(Date().timeIntervalSince1970))
    let txid = Data([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    let sync = { (s: Int, m: Int) -> Data in
        vi(1, 128) + vi(2, m) + ld(16, Data([0x08]) + ts + Data([0x10]) + txid)
    }
    return [
        packet(1, 0x80, 0x00, vi(1,4) + vi(2,0x0C) + ld(3, vi(1,1) + vi(2,4))),
        packet(2, 0x80, 0x20, vi(1,5) + vi(2,0x0E) + ld(4, vi(1,2))),
        packet(3, 0x80, 0x20, sync(3, 0x0F)),
        packet(4, 0x80, 0x00, vi(1,4) + vi(2,0x10) + ld(3, vi(1,1) + vi(2,4))),
        packet(5, 0x80, 0x00, vi(1,4) + vi(2,0x11) + ld(3, vi(1,1) + vi(2,4))),
        packet(6, 0x80, 0x20, vi(1,5) + vi(2,0x12) + ld(4, vi(1,1))),
        packet(7, 0x80, 0x20, sync(7, 0x13)),
    ]
}

private func aiEnter(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x07, 0x20, vi(1,1) + vi(2,mid) + ld(3, vi(1,2)))
}

private func aiQuestion(_ seq: Int, _ mid: Int, _ text: String) -> Data {
    let info = vi(1,0) + vi(2,0) + vi(3,0) + ld(4, Data(text.utf8))
    return packet(seq, 0x07, 0x20, vi(1,3) + vi(2,mid) + ld(5, info))
}

private func aiReply(_ seq: Int, _ mid: Int, _ text: String) -> Data {
    let info = vi(1,0) + vi(2,0) + vi(3,0) + ld(4, Data(text.utf8))
    return packet(seq, 0x07, 0x20, vi(1,5) + vi(2,mid) + ld(7, info))
}

private func authHeartbeat(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x80, 0x00, vi(1, 0x0E) + vi(2, mid) + ld(13, Data()))
}

private func aiHeartbeat(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x07, 0x20, vi(1, 9) + vi(2, mid))
}

private func aiExit(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x07, 0x20, vi(1,1) + vi(2,mid) + ld(3, vi(1,3)))
}

/// Extract f10.f1 from AI EVENT protobuf payload (touch type)
private func touchType(_ payload: Data) -> UInt8? {
    let bytes = [UInt8](payload)
    for i in 0..<(bytes.count - 3) {
        if bytes[i] == 0x52 && i + 3 < bytes.count && bytes[i + 2] == 0x08 {
            return bytes[i + 3]
        }
    }
    return nil
}

// MARK: - BLE

enum Mode { case text, ask }

final class GlassesBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripherals: [CBPeripheral] = []
    private var txChars: [CBPeripheral: CBCharacteristic] = [:]
    private var text = ""
    private var mode: Mode = .text
    private var done = false
    private var sent = false
    private var touched = false
    private var authenticated = 0
    private var scanTimer: Timer?
    private var heartbeatTimer: Timer?
    private var seq = 8
    private var mid = 0x14
    private var timeout: TimeInterval = 25
    private var touchReady = false
    private let verbose: Bool

    init(verbose: Bool = false) {
        self.verbose = verbose
    }

    private func log(_ msg: String) {
        if verbose { fputs(msg, stderr) }
    }

    private func nextId() -> (Int, Int) {
        let s = seq, m = mid
        seq += 1; mid += 1
        return (s, m)
    }

    private func writeAll(_ data: Data) {
        for (p, tx) in txChars {
            p.writeValue(data, for: tx, type: .withoutResponse)
        }
    }

    func send(_ text: String) -> Int32 {
        self.text = text
        self.mode = .text
        self.timeout = 25
        return run()
    }

    func ask(_ text: String, timeout: TimeInterval = 30) -> Int32 {
        self.text = text
        self.mode = .ask
        self.timeout = timeout + 15 // extra for scan+connect
        return run()
    }

    private func run() -> Int32 {
        central = CBCentralManager(delegate: self, queue: nil)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done && RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) {
            if Date() > deadline {
                log("Timeout\n")
                return mode == .ask ? (touched ? 0 : 1) : (sent ? 0 : 1)
            }
        }
        return mode == .ask ? (touched ? 0 : 1) : (sent ? 0 : 1)
    }

    // MARK: - Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized {
                fputs("Bluetooth permission denied\n", stderr)
                done = true
            }
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    private func stopScan() {
        central.stopScan()
        scanTimer?.invalidate()
        if peripherals.isEmpty {
            fputs("No G2 glasses found\n", stderr)
            done = true
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard let name = peripheral.name, name.hasPrefix("Even G2") else { return }
        guard !peripherals.contains(peripheral) else { return }

        // For ask mode, only connect to R eye (touch events are right-eye only)
        if mode == .ask && name.contains("_L_") { return }

        let side = name.contains("_L_") ? "L" : name.contains("_R_") ? "R" : "?"
        log("  \(side): \(name)\n")
        peripherals.append(peripheral)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        let target = mode == .ask ? 1 : 2
        if peripherals.count >= target {
            central.stopScan()
            scanTimer?.invalidate()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([EUS_SVC, NUS_SVC])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fputs("Connect failed: \(error?.localizedDescription ?? "unknown")\n", stderr)
        peripherals.removeAll { $0 == peripheral }
        if peripherals.isEmpty { done = true }
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = peripheral.services else { return }
        guard let eus = svcs.first(where: { $0.uuid == EUS_SVC }) else {
            fputs("EUS service not found\n", stderr)
            return
        }
        peripheral.discoverCharacteristics([EUS_TX, EUS_RX], for: eus)
        if let nus = svcs.first(where: { $0.uuid == NUS_SVC }) {
            peripheral.discoverCharacteristics([NUS_RX], for: nus)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }

        // NUS service — just subscribe to RX for gesture events
        if service.uuid == NUS_SVC {
            if let rx = chars.first(where: { $0.uuid == NUS_RX }) {
                peripheral.setNotifyValue(true, for: rx)
                log("  NUS: subscribed\n")
            }
            return
        }

        // EUS service — auth + subscribe
        guard let tx = chars.first(where: { $0.uuid == EUS_TX }) else {
            fputs("EUS TX not found\n", stderr)
            return
        }
        txChars[peripheral] = tx

        if let rx = chars.first(where: { $0.uuid == EUS_RX }) {
            peripheral.setNotifyValue(true, for: rx)
        }

        for pkt in authPackets() {
            peripheral.writeValue(pkt, for: tx, type: .withoutResponse)
        }
        let side = peripheral.name?.contains("_L_") == true ? "L" : "R"
        log("  \(side): authenticated\n")
        authenticated += 1

        if authenticated >= peripherals.count {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.sendDisplay()
            }
        }
    }

    // MARK: - RX notifications (touch events)

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        guard mode == .ask else { return }

        // NUS gesture events: 0xF5 prefix (primary touch channel)
        if characteristic.uuid == NUS_RX {
            let bytes = [UInt8](data)
            guard bytes.count >= 2, bytes[0] == 0xF5 else { return }
            let gesture = bytes[1]
            // 0x01=tap, 0x00=double-tap, 0x17=long-press
            log("  rx: NUS F5 \(String(format:"%02X", gesture)) ready=\(touchReady)\n")
            guard gesture == 0x01 || gesture == 0x00 || gesture == 0x17 else { return }
            guard touchReady else { return }
            log("  touch detected (NUS)\n")
            touched = true
            disconnectAll()
            return
        }

        // EUS protobuf events: fallback touch channel
        guard characteristic.uuid == EUS_RX, data.count >= 10 else { return }
        let bytes = [UInt8](data)
        guard bytes[0] == 0xAA else { return }
        let svcHi = bytes[6], svcLo = bytes[7]
        guard svcHi == 0x07, svcLo == 0x01 else { return }
        let payload = data.subdata(in: 8..<(data.count - 2))
        guard payload.count > 2, payload[0] == 0x08, payload[1] == 0x08 else { return }
        let tt = touchType(payload)
        log("  rx: 07-01 f10.f1=\(tt.map { String($0) } ?? "nil") ready=\(touchReady)\n")
        guard tt == 0x01 || tt == 0x02 else { return }
        guard touchReady else { return }
        log("  touch detected (EUS)\n")
        touched = true
        disconnectAll()
    }

    // MARK: - Display

    private func sendDisplay() {
        let (s, m) = nextId()
        writeAll(aiEnter(s, m))

        if mode == .ask {
            // Start heartbeats immediately to keep AI alive
            startDualHeartbeat()

            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (qs, qm) = self.nextId()
                self.writeAll(aiQuestion(qs, qm, self.text))
            }
            Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (rs, rm) = self.nextId()
                self.writeAll(aiReply(rs, rm, "[press+hold = yes]"))
                self.sent = true
            }
            // Drain phantom events for 1.5s after display, then arm touch detection
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.touchReady = true
                log("  waiting for touch...\n")
            }
            // Ask timeout
            let askTimeout = self.timeout - 15
            Timer.scheduledTimer(withTimeInterval: max(askTimeout, 5) + 1.5, repeats: false) { [weak self] _ in
                guard let self = self, !self.touched else { return }
                self.disconnectAll()
            }
        } else {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (rs, rm) = self.nextId()
                self.writeAll(aiReply(rs, rm, self.text))
                self.sent = true
                let label = self.peripherals.count > 1 ? "L+R" : (self.peripherals.first?.name?.contains("_L_") == true ? "L" : "R")
                self.log("  \(label): sent\n")
                self.startTextKeepalive()
            }
        }
    }

    private func startTextKeepalive() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let (s, m) = self.nextId()
            self.writeAll(authHeartbeat(s, m))
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.disconnectAll()
        }
    }

    private func startDualHeartbeat() {
        // Send first heartbeat immediately
        let (s1, m1) = nextId()
        writeAll(aiHeartbeat(s1, m1))
        let (s2, m2) = nextId()
        writeAll(authHeartbeat(s2, m2))

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let (s1, m1) = self.nextId()
            self.writeAll(aiHeartbeat(s1, m1))
            let (s2, m2) = self.nextId()
            self.writeAll(authHeartbeat(s2, m2))
        }
    }

    private func disconnectAll() {
        heartbeatTimer?.invalidate()
        if mode == .ask {
            let (s, m) = nextId()
            writeAll(aiExit(s, m))
        }
        // Brief delay to let exit packet flush before disconnect
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            for p in self.peripherals { self.central.cancelPeripheralConnection(p) }
            self.done = true
        }
    }
}
