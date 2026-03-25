import CoreBluetooth
import Foundation

// Even UART Service (EUS) — the authenticated protocol that drives the display
private let EUS_SVC = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5450")
private let EUS_TX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5401")
private let EUS_RX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5402")

// Nordic UART Service (NUS) — raw gesture events (0xF5 prefix)
private let NUS_SVC = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let NUS_TX  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
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

/// Decode protobuf fields from raw bytes
private func decodeProto(_ data: Data) -> [(field: Int, wire: Int, value: String)] {
    var fields: [(field: Int, wire: Int, value: String)] = []
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        let tag = Int(bytes[i]); i += 1
        let field = tag >> 3, wire = tag & 0x07
        switch wire {
        case 0: // varint
            var v = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]); i += 1
                v |= (b & 0x7F) << shift; shift += 7
                if b & 0x80 == 0 { break }
            }
            fields.append((field, wire, "\(v)"))
        case 2: // length-delimited
            var len = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]); i += 1
                len |= (b & 0x7F) << shift; shift += 7
                if b & 0x80 == 0 { break }
            }
            let end = min(i + len, bytes.count)
            let sub = Data(bytes[i..<end])
            let hex = sub.map { String(format: "%02X", $0) }.joined(separator: " ")
            // Try to decode nested protobuf
            let nested = decodeProto(sub)
            if !nested.isEmpty && nested.allSatisfy({ $0.field > 0 && $0.field < 20 }) {
                let inner = nested.map { "f\($0.field)=\($0.value)" }.joined(separator: " ")
                fields.append((field, wire, "{\(inner)}"))
            } else {
                fields.append((field, wire, "[\(hex)]"))
            }
            i = end
        default:
            fields.append((field, wire, "?wire\(wire)"))
            break
        }
    }
    return fields
}

// MARK: - BLE

enum Mode { case text, ask, dump, notify }

final class GlassesBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripherals: [CBPeripheral] = []
    private var txChars: [CBPeripheral: CBCharacteristic] = [:]
    private var nusTxChars: [CBPeripheral: CBCharacteristic] = [:]
    private var text = ""
    private var mode: Mode = .text
    private var done = false
    private var sent = false
    private var touched = false
    private var swipeFwd = 0
    private var swipeBack = 0
    private var lastSwipeX: Int? = nil
    private var swipeStartX: Int? = nil
    private var contactCount = 0
    private var authenticated = 0
    private var scanTimer: Timer?
    private var heartbeatTimer: Timer?
    private var seq = 8
    private var mid = 0x14
    private var timeout: TimeInterval = 25
    private var touchReady = false
    private var inAIMode = false
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

    func dump(duration: TimeInterval = 30) -> Int32 {
        self.text = "dump mode"
        self.mode = .dump
        self.timeout = duration + 15
        return run()
    }

    func notify(title: String, message: String, timeout: TimeInterval = 30) -> Int32 {
        self.text = message
        self.mode = .notify
        self.timeout = timeout + 15  // extra for scan+connect
        self.notifyTitle = title
        return run()
    }

    private var notifyTitle = ""

    private func run() -> Int32 {
        central = CBCentralManager(delegate: self, queue: nil)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done && RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) {
            if Date() > deadline {
                log("Timeout\n")
                if mode == .ask || mode == .notify { return touched ? 0 : 1 }
                return sent ? 0 : 1
            }
        }
        if mode == .ask || mode == .notify { return touched ? 0 : 1 }
        return sent ? 0 : 1
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

        // For ask/dump/notify mode, only connect to R eye (touch events are right-eye only)
        if (mode == .ask || mode == .dump || mode == .notify) && name.contains("_L_") { return }

        let side = name.contains("_L_") ? "L" : name.contains("_R_") ? "R" : "?"
        log("  \(side): \(name)\n")
        peripherals.append(peripheral)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        let target = (mode == .ask || mode == .dump || mode == .notify) ? 1 : 2
        if peripherals.count >= target {
            central.stopScan()
            scanTimer?.invalidate()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if mode == .notify {
            // Use AI overlay for notifications (NOTIF panel requires iOS ANCS)
            peripheral.discoverServices([EUS_SVC, NUS_SVC])
        } else if mode == .dump {
            peripheral.discoverServices(nil)
        } else {
            peripheral.discoverServices([EUS_SVC, NUS_SVC])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fputs("Connect failed: \(error?.localizedDescription ?? "unknown")\n", stderr)
        peripherals.removeAll { $0 == peripheral }
        if peripherals.isEmpty { done = true }
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = peripheral.services else { return }
        if mode == .notify || mode == .dump {
            for svc in svcs {
                log("  svc: \(svc.uuid)\n")
                peripheral.discoverCharacteristics(nil, for: svc)
            }
            return
        }
        guard let eus = svcs.first(where: { $0.uuid == EUS_SVC }) else {
            fputs("EUS service not found\n", stderr)
            return
        }
        peripheral.discoverCharacteristics([EUS_TX, EUS_RX], for: eus)
        if let nus = svcs.first(where: { $0.uuid == NUS_SVC }) {
            peripheral.discoverCharacteristics([NUS_TX, NUS_RX], for: nus)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }

        // NUS service
        if service.uuid == NUS_SVC {
            if let tx = chars.first(where: { $0.uuid == NUS_TX }) {
                nusTxChars[peripheral] = tx
                if let rx = chars.first(where: { $0.uuid == NUS_RX }) {
                    peripheral.setNotifyValue(true, for: rx)
                }
                let side = peripheral.name?.contains("_L_") == true ? "L" : "R"
                let props = tx.properties
                log("  NUS \(side) TX: write=\(props.contains(.write)) writeNoResp=\(props.contains(.writeWithoutResponse))\n")
                // Init handshake (0x4D 0x01) — required before NUS commands work
                let wt: CBCharacteristicWriteType = props.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.writeValue(Data([0x4D, 0x01]), for: tx, type: wt)
                log("  NUS \(side): 0x4D init sent\n")

            }
            return
        }

        // EUS service — auth + subscribe
        guard service.uuid == EUS_SVC else { return }
        guard let tx = chars.first(where: { $0.uuid == EUS_TX }) else { return }
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

        // Log all RX in verbose mode regardless of command mode
        if verbose && characteristic.uuid == EUS_RX && data.count >= 10 {
            let b = [UInt8](data)
            if b[0] == 0xAA {
                let svc = String(format: "%02X-%02X", b[6], b[7])
                // Full decode for 01-01 and 09-01 to understand gesture data
                if (b[6] == 0x01 || b[6] == 0x02 || b[6] == 0x04 || b[6] == 0x07 || b[6] == 0x09 || b[6] == 0x0D || b[6] == 0x80) {
                    let payload = data.subdata(in: 8..<(data.count - 2))
                    let fields = decodeProto(payload)
                    let decoded = fields.map { "f\($0.field)=\($0.value)" }.joined(separator: " ")
                    log("  rx: \(svc) seq=\(b[2]) \(decoded)\n")
                } else {
                    log("  rx: \(svc) seq=\(b[2]) len=\(b[3])\n")
                }
            }
        }

        guard mode == .ask || mode == .dump || mode == .notify else { return }

        // NUS responses
        if characteristic.uuid == NUS_RX {
            let bytes = [UInt8](data)
            if mode == .dump {
                let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                fputs("NUS  \(hex)\n", stderr)
                if bytes.count >= 2 && bytes[0] == 0xF5 {
                    let names: [UInt8: String] = [0x00:"double-tap", 0x01:"tap", 0x02:"slide-fwd",
                        0x03:"slide-back", 0x04:"triple-tap-L", 0x05:"triple-tap-R",
                        0x17:"long-press", 0x24:"release"]
                    fputs("     gesture=0x\(String(format:"%02X", bytes[1])) \(names[bytes[1]] ?? "?")\n", stderr)
                }
                return
            }
            // ask + notify: gesture detection via NUS F5
            guard bytes.count >= 2, bytes[0] == 0xF5 else { return }
            let gesture = bytes[1]
            log("  rx: NUS F5 \(String(format:"%02X", gesture)) ready=\(touchReady)\n")
            guard touchReady else { return }
            if gesture == 0x02 { // slide-fwd
                swipeFwd += 1
                swipeBack = 0
                log("  swipe fwd (\(swipeFwd)/2)\n")
                if swipeFwd >= 2 { touched = true; disconnectAll() }
            } else if gesture == 0x03 { // slide-back
                swipeBack += 1
                swipeFwd = 0
                log("  swipe back (\(swipeBack)/2)\n")
                if swipeBack >= 2 { disconnectAll() }
            }
            return
        }

        // EUS protobuf events
        guard characteristic.uuid == EUS_RX, data.count >= 10 else { return }
        let bytes = [UInt8](data)
        guard bytes[0] == 0xAA else { return }
        let svcHi = bytes[6], svcLo = bytes[7]

        if mode == .dump {
            let payload = data.subdata(in: 8..<(data.count - 2))
            let hex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            let svc = String(format: "%02X-%02X", svcHi, svcLo)
            let fields = decodeProto(payload)
            let decoded = fields.map { "f\($0.field)=\($0.value)" }.joined(separator: " ")
            fputs("EUS  \(svc) seq=\(bytes[2]) len=\(bytes[3])  \(decoded)\n", stderr)
            if verbose { fputs("     \(hex)\n", stderr) }
            return
        }

        // Ask mode: gesture detection on 01-01 (dashboard gestures)
        // f5.f2.f1 = X position (0-4ish), absent f1 = 0. Track start→end per stroke.
        if svcHi == 0x01, svcLo == 0x01 {
            let payload = data.subdata(in: 8..<(data.count - 2))
            let fields = decodeProto(payload)
            for f in fields where f.field == 6 {
                log("  rx: 01-01 f6=\(f.value) ready=\(touchReady)\n")
                guard touchReady else { continue }
                if f.value.contains("f5=") {
                    // Extract X from f5={...f2={f1=X...} or f2={f2=Y} (X=0 when f1 absent)
                    var xPos = 0
                    if let f5r = f.value.range(of: "f5={") {
                        let sub = f.value[f5r.upperBound...]
                        if let f2r = sub.range(of: "f2={f1=") {
                            let numStart = sub[f2r.upperBound...]
                            if let end = numStart.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) {
                                xPos = Int(numStart[..<end.lowerBound]) ?? 0
                            }
                        }
                        // else f2={f2=...} means f1 absent → X=0
                    }
                    if swipeStartX == nil { swipeStartX = xPos }
                    lastSwipeX = xPos
                    log("  touch x=\(xPos) start=\(swipeStartX ?? -1)\n")
                    armSwipeTimeout()
                }
                if f.value.contains("f3=") {
                    classifySwipe()
                }
            }
            return
        }

        // Ask mode: swipe detection on 07-01 (AI touch events)
        // Accumulate contacts with 0.5s debounce timer. 3+ contacts = swipe.
        guard svcHi == 0x07, svcLo == 0x01 else { return }
        let payload = data.subdata(in: 8..<(data.count - 2))
        guard payload.count > 2, payload[0] == 0x08 else { return }

        if payload[1] == 0x08 {
            // Touch EVENT
            let tt = touchType(payload)
            guard touchReady else { return }
            if tt == 0x02 { // slide-fwd
                swipeFwd += 1; swipeBack = 0
                log("  EUS swipe fwd (\(swipeFwd)/2)\n")
                if swipeFwd >= 2 { touched = true; disconnectAll() }
            } else if tt == 0x03 { // slide-back
                swipeBack += 1; swipeFwd = 0
                log("  EUS swipe back (\(swipeBack)/2)\n")
                if swipeBack >= 2 { disconnectAll() }
            } else if tt == 0x01 { // tap/contact
                contactCount += 1
                swipeTimer?.invalidate()
                swipeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    self?.classifyGesture()
                }
            }
        } else if payload[1] == 0x01 {
            // Release — classify immediately
            guard touchReady else { return }
            swipeTimer?.invalidate()
            classifyGesture()
        }
    }

    // MARK: - Display



    private func sendDisplay() {
        if mode == .notify {
            guard !sent else { return }
            sent = true

            // AI overlay for notification display (notification panel requires iOS ANCS)
            let (es, em) = nextId()
            writeAll(aiEnter(es, em))
            inAIMode = true
            log("  aiEnter sent\n")
            startDualHeartbeat()

            // Show title as question, message as reply
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (qs, qm) = self.nextId()
                self.writeAll(aiQuestion(qs, qm, self.notifyTitle))
            }
            Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (rs, rm) = self.nextId()
                let reply = self.text + "\n[fwd x2 = yes | wait = no]"
                self.writeAll(aiReply(rs, rm, reply))
            }
            // Drain phantom events, then arm touch detection
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.touchReady = true
            }
            // Timeout (subtract scan+connect overhead)
            let notifyTimeout = self.timeout - 15
            Timer.scheduledTimer(withTimeInterval: max(notifyTimeout, 5) + 1.5, repeats: false) { [weak self] _ in
                guard let self = self, !self.touched else { return }
                self.disconnectAll()
            }
            return
        }

        if mode == .dump {
            // Don't enter AI mode — just auth heartbeat to stay connected
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let (s, m) = self.nextId()
                self.writeAll(authHeartbeat(s, m))
            }
            fputs("Listening for packets (\(Int(timeout - 15))s)...\n", stderr)
            let dumpTimeout = self.timeout - 15
            Timer.scheduledTimer(withTimeInterval: max(dumpTimeout, 5), repeats: false) { [weak self] _ in
                self?.disconnectAll()
            }
            return
        }

        if mode == .ask {
            // AI mode + double-tap detection
            let (es, em) = nextId()
            writeAll(aiEnter(es, em))
            inAIMode = true
            log("  aiEnter sent\n")
            startDualHeartbeat()

            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (qs, qm) = self.nextId()
                self.writeAll(aiQuestion(qs, qm, self.text))
            }
            Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (rs, rm) = self.nextId()
                self.writeAll(aiReply(rs, rm, "[swipe fwd x2 = yes | wait = no]"))
                self.sent = true
            }
            // Drain phantom events for 1.5s, then arm touch detection
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.touchReady = true
                self.log("  waiting for taps...\n")
            }
            // Ask timeout
            let askTimeout = self.timeout - 15
            Timer.scheduledTimer(withTimeInterval: max(askTimeout, 5) + 1.5, repeats: false) { [weak self] _ in
                guard let self = self, !self.touched else { return }
                self.disconnectAll()
            }
        } else {
            // AI mode: enter → heartbeat → reply
            let (es, em) = nextId()
            writeAll(aiEnter(es, em))
            inAIMode = true
            log("  aiEnter sent\n")
            startDualHeartbeat()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
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
        // Keep dual heartbeat (AI + auth) so display stays visible
        // startDualHeartbeat already running — just set disconnect timer
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

    private var swipeTimer: Timer?

    private func classifyGesture() {
        if contactCount >= 3 {
            swipeFwd += 1
            log("  SWIPE \(swipeFwd)/2 (\(contactCount) contacts)\n")
            if swipeFwd >= 2 { touched = true; disconnectAll() }
        } else if contactCount > 0 {
            log("  tap ignored (\(contactCount))\n")
        }
        contactCount = 0
    }

    private func classifySwipe() {
        swipeTimer?.invalidate()
        guard let start = swipeStartX, let end = lastSwipeX else {
            swipeStartX = nil; lastSwipeX = nil; return
        }
        let delta = end - start
        log("  stroke done: start=\(start) end=\(end) delta=\(delta)\n")
        if delta > 0 { swipeFwd += 1; swipeBack = 0; log("  FWD (\(swipeFwd)/2)\n") }
        else if delta < 0 { swipeBack += 1; swipeFwd = 0; log("  BACK (\(swipeBack)/2)\n") }
        swipeStartX = nil; lastSwipeX = nil
        if swipeFwd >= 2 { touched = true; disconnectAll() }
        else if swipeBack >= 2 { disconnectAll() }
    }

    private func armSwipeTimeout() {
        swipeTimer?.invalidate()
        swipeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.classifySwipe()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let side = peripheral.name?.contains("_L_") == true ? "L" : "R"
            log("  write error \(side) \(characteristic.uuid): \(error.localizedDescription)\n")
        }
    }

    private func disconnectAll() {
        heartbeatTimer?.invalidate()
        if inAIMode {
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
