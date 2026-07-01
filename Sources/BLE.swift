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

// Display Pipe Service (DPS) — Hub/container rendering pipe
private let DPS_SVC = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e6450")
private let DPS_TX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e6401")
private let DPS_RX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e6402")

private let HUB_SVC = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e1001")
private let HUB_TX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e0001")
private let HUB_RX  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e0002")



// MARK: - Protobuf helpers

private func varint(_ v: Int) -> Data {
    var v = v; var r = Data()
    while v > 0x7F { r.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
    r.append(UInt8(v & 0x7F))
    return r
}

private func vi(_ field: Int, _ value: Int) -> Data {
    varint(field << 3) + varint(value)
}

private func ld(_ field: Int, _ data: Data) -> Data {
    varint(field << 3 | 2) + varint(data.count) + data
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
        vi(1, 128) + vi(2, m) + ld(128, Data([0x08]) + ts + Data([0x10]) + txid)
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

// Conversate mode (0x0B) — required to activate mic on DPS pipe (6402)
private func conversateInit(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x0B, 0x20, vi(1, 1) + vi(2, mid))
}

private func conversateStop(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x0B, 0x20, vi(1, 1) + vi(2, mid) + ld(3, vi(1, 2)))
}

private func conversateHeartbeat(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x0B, 0x20, vi(1, 0xFF) + vi(2, mid))
}

private func conversateText(_ seq: Int, _ mid: Int, _ text: String, isFinal: Bool = true) -> Data {
    packet(seq, 0x0B, 0x20, vi(1, 6) + vi(2, mid) + ld(8, Data(text.utf8) + Data([isFinal ? 1 : 0])))
}

private func conversateUserPrompt(_ seq: Int, _ mid: Int, _ text: String) -> Data {
    packet(seq, 0x0B, 0x20, vi(1, 7) + vi(2, mid) + ld(9, Data(text.utf8)))
}


private func aiExit(_ seq: Int, _ mid: Int) -> Data {
    packet(seq, 0x07, 0x20, vi(1,1) + vi(2,mid) + ld(3, vi(1,3)))
}

private func hubProbe(_ seq: Int, _ mid: Int, _ type: Int) -> Data {
    packet(seq, 0x07, 0x20, vi(1, type) + vi(2, mid))
}

private func textContainer(_ text: String) -> Data {
    var d = vi(1, 0) + vi(2, 0)         // X=0, Y=0
    d += vi(3, 576) + vi(4, 288)        // Width x Height (full screen)
    d += vi(5, 0) + vi(6, 15)           // Border_Width=0, Border_Color=15 (white)
    d += vi(7, 0) + vi(8, 4)            // Border_Radius=0, Padding=4
    d += vi(9, 1) + ld(10, Data("t1".utf8))  // Container_ID=1, Name="t1"
    d += vi(11, 1)                       // Is_event_capture=1
    d += ld(12, Data(text.utf8))         // Content
    return d
}

// Hub command on 0x07-20 — nested in f(type+2), matching EvenAI convention
private func hubCmd07(_ seq: Int, _ mid: Int, type t: Int, payload: Data = Data()) -> Data {
    packet(seq, 0x07, 0x20,
        vi(1, t) + vi(2, mid) + (payload.isEmpty ? Data() : ld(t + 2, payload)))
}

// Hub shutdown — type 12 with exitMode=0 (immediate)
private func hubShutdown(_ seq: Int, _ mid: Int) -> Data {
    hubCmd07(seq, mid, type: 12, payload: vi(1, 0))
}




// MARK: - BLE

enum Mode { case text, ask, dump, notify, lab, bond }

final class GlassesBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripherals: [CBPeripheral] = []
    private var txChars: [CBPeripheral: CBCharacteristic] = [:]
    private var nusTxChars: [CBPeripheral: CBCharacteristic] = [:]
    private var dpsTxChars: [CBPeripheral: CBCharacteristic] = [:]
    private var hubTxChars: [CBPeripheral: CBCharacteristic] = [:]
    private var text = ""
    private var mode: Mode = .text
    private var done = false
    private var sent = false
    private var touched = false
    private var swipeCount = 0
    private var lastContactTime: Date?
    private var authenticated = 0
    private var scanTimer: Timer?
    private var heartbeatTimer: Timer?
    private var seq = 8
    private var mid = 0x14
    private var timeout: TimeInterval = 25
    private var touchReady = false
    private var inAIMode = false
    private let verbose: Bool
    private var labDisplay = "bare"
    private var labMic = false
    private var startTime = Date()
    private var audioFrames = 0
    private var audioFileHandle: FileHandle?
    private var inConversate = false
    private var conversateHBTimer: Timer?
    private var dpsRxChars: [CBPeripheral: CBCharacteristic] = [:]
    private var bondCharCount = 0
    private var bondReadCount = 0

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

    private func writeDPS(_ data: Data) {
        for (p, tx) in dpsTxChars {
            p.writeValue(data, for: tx, type: .withoutResponse)
        }
    }

    private func writeHUB(_ data: Data) {
        for (p, tx) in hubTxChars {
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

    func lab(display: String, text: String, mic: Bool, duration: TimeInterval) -> Int32 {
        self.text = text
        self.mode = .lab
        self.labDisplay = display
        self.labMic = mic
        self.timeout = duration + 15
        return run()
    }

    func bond(timeout: TimeInterval = 30) -> Int32 {
        self.mode = .bond
        self.timeout = timeout + 15
        return run()
    }

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
        // Try to retrieve already-connected G2 peripherals (e.g. paired to another device)
        let connected = central.retrieveConnectedPeripherals(withServices: [EUS_SVC])
        for p in connected where (p.name ?? "").hasPrefix("Even G2") {
            log("  retrieved connected: \(p.name ?? "?")\n")
            if !peripherals.contains(p) {
                peripherals.append(p)
                p.delegate = self
                central.connect(p, options: nil)
            }
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

        // For ask/notify mode, only connect to R eye (touch events are right-eye only)
        // For lab --mic, connect BOTH eyes (mic needs both connected)
        let micNeedsBoth = mode == .lab && labMic
        if !micNeedsBoth && (mode == .ask || mode == .dump || mode == .notify || mode == .lab || mode == .bond) && name.contains("_L_") { return }

        let side = name.contains("_L_") ? "L" : name.contains("_R_") ? "R" : "?"
        log("  \(side): \(name)\n")
        peripherals.append(peripheral)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        let target = micNeedsBoth ? 2 : (mode == .ask || mode == .dump || mode == .notify || mode == .lab || mode == .bond) ? 1 : 2
        if peripherals.count >= target {
            central.stopScan()
            scanTimer?.invalidate()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if mode == .bond {
            fputs("Connected — discovering all services...\n", stderr)
            peripheral.discoverServices(nil)
            Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                self?.bondTryMic()
            }
            let bondDuration = self.timeout - 15
            Timer.scheduledTimer(withTimeInterval: max(bondDuration, 10), repeats: false) { [weak self] _ in
                self?.bondReport()
                self?.disconnectAll()
            }
            return
        }
        if mode == .notify {
            // Use AI overlay for notifications (NOTIF panel requires iOS ANCS)
            peripheral.discoverServices([EUS_SVC, NUS_SVC])
        } else if mode == .dump {
            peripheral.discoverServices(nil)
        } else {
            peripheral.discoverServices(nil)  // Discover ALL services
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
        if mode == .bond || mode == .notify || mode == .dump {
            for svc in svcs {
                log("  svc: \(svc.uuid)\n")
                peripheral.discoverCharacteristics(nil, for: svc)
            }
            return
        }
        // Log all discovered services
        for svc in svcs {
            let uuid = svc.uuid.uuidString
            if uuid != EUS_SVC.uuidString && uuid != NUS_SVC.uuidString {
                log("  svc: \(uuid)\n")
            }
        }
        guard let eus = svcs.first(where: { $0.uuid == EUS_SVC }) else {
            fputs("EUS service not found\n", stderr)
            return
        }
        peripheral.discoverCharacteristics([EUS_TX, EUS_RX], for: eus)
        if let nus = svcs.first(where: { $0.uuid == NUS_SVC }) {
            peripheral.discoverCharacteristics([NUS_TX, NUS_RX], for: nus)
        }
        if let dps = svcs.first(where: { $0.uuid == DPS_SVC }) {
            peripheral.discoverCharacteristics(nil, for: dps)
            log("  DPS: found!\n")
        }
        if let hub = svcs.first(where: { $0.uuid == HUB_SVC }) {
            peripheral.discoverCharacteristics([HUB_TX, HUB_RX], for: hub)
            log("  HUB pipe: found!\n")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }

        // Bond mode — enumerate all chars, try reads to trigger SMP pairing
        if mode == .bond {
            let svcId = service.uuid.uuidString
            let known: [String: String] = [
                "180A": "Device Info", "1800": "Generic Access", "1801": "Generic Attribute",
                "00002760-08C2-11E1-9073-0E8AC72E5450": "Even UART",
                "6E400001-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART",
            ]
            let label = known[svcId].map { " (\($0))" } ?? ""
            fputs("\n  \(svcId)\(label)\n", stderr)

            for char in chars {
                bondCharCount += 1
                let props = bondPropsString(char)
                fputs("    \(char.uuid) [\(props)]\n", stderr)
                // Read to probe for encryption requirements
                if char.properties.contains(.read) {
                    peripheral.readValue(for: char)
                }
                // Subscribe — notify/indicate-encrypted chars trigger pairing
                if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
            // Store NUS TX for mic test
            if service.uuid == NUS_SVC {
                if let tx = chars.first(where: { $0.uuid == NUS_TX }) {
                    nusTxChars[peripheral] = tx
                    let wt: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                    peripheral.writeValue(Data([0x4D, 0x01]), for: tx, type: wt)
                    fputs("    NUS init handshake sent\n", stderr)
                }
            }
            return
        }

        // Display Pipe Service
        if service.uuid == DPS_SVC {
            if let tx = chars.first(where: { $0.uuid == DPS_TX }) {
                dpsTxChars[peripheral] = tx
                let side = peripheral.name?.contains("_L_") == true ? "L" : "R"
                log("  DPS \(side): connected\n")
            }
            if let rx = chars.first(where: { $0.uuid == DPS_RX }) {
                dpsRxChars[peripheral] = rx
                // Only auto-subscribe in dump mode; mic mode subscribes after Conversate init
                if mode == .dump {
                    peripheral.setNotifyValue(true, for: rx)
                }
            }
            return
        }

        // Hub Pipe Service (0x1001)
        if service.uuid == HUB_SVC {
            if let tx = chars.first(where: { $0.uuid == HUB_TX }) {
                hubTxChars[peripheral] = tx
                let side = peripheral.name?.contains("_L_") == true ? "L" : "R"
                log("  HUB \(side): connected\n")
            }
            if let rx = chars.first(where: { $0.uuid == HUB_RX }) {
                peripheral.setNotifyValue(true, for: rx)
            }
            return
        }

        // NUS service
        if service.uuid == NUS_SVC {
            let side = peripheral.name?.contains("_L_") == true ? "L" : "R"
            for c in chars {
                let p = c.properties
                var ps: [String] = []
                if p.contains(.read) { ps.append("read") }
                if p.contains(.write) { ps.append("write") }
                if p.contains(.writeWithoutResponse) { ps.append("writeNoResp") }
                if p.contains(.notify) { ps.append("notify") }
                if p.contains(.indicate) { ps.append("indicate") }
                log("  NUS \(side) \(c.uuid.uuidString): [\(ps.joined(separator: ", "))]\n")
            }
            if let tx = chars.first(where: { $0.uuid == NUS_TX }) {
                nusTxChars[peripheral] = tx
                // Init handshake
                let wt: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.writeValue(Data([0x4D, 0x01]), for: tx, type: wt)
                log("  NUS \(side): 0x4D init sent\n")
            }
            if let rx = chars.first(where: { $0.uuid == NUS_RX }) {
                peripheral.setNotifyValue(true, for: rx)
                log("  NUS \(side) RX: notify subscribed\n")
            }
            // Also try subscribing to TX char for notifications (in case roles are swapped)
            if let tx = chars.first(where: { $0.uuid == NUS_TX }), tx.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: tx)
                log("  NUS \(side) TX: also has notify — subscribed!\n")
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
        // Bond mode: catch auth errors that trigger SMP pairing
        if mode == .bond {
            let uuid = characteristic.uuid.uuidString
            if let err = error as NSError? {
                bondReadCount += 1
                if err.domain == CBATTErrorDomain && (err.code == 5 || err.code == 15) {
                    fputs("    → \(uuid): *** REQUIRES ENCRYPTION — pairing initiated ***\n", stderr)
                } else {
                    fputs("    → \(uuid): error \(err.code) \(err.localizedDescription)\n", stderr)
                }
            } else if let data = characteristic.value, !data.isEmpty {
                bondReadCount += 1
                if characteristic.uuid == NUS_RX {
                    let bytes = [UInt8](data)
                    if bytes.first == 0x0E && bytes.count >= 3 {
                        let status = NUSMicStatus(rawValue: bytes[1])
                        fputs("    mic response: \(status?.description ?? "0x\(String(format: "%02X", bytes[1]))") enable=\(bytes[2])\n", stderr)
                    } else {
                        let hex = bytes.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                        fputs("    NUS RX: \(hex)\n", stderr)
                    }
                } else {
                    let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    let trunc = data.count > 16 ? "..." : ""
                    fputs("    → \(uuid): \(data.count)B \(hex)\(trunc)\n", stderr)
                }
            }
            return
        }

        guard let data = characteristic.value, !data.isEmpty else { return }

        // Log all RX in verbose mode regardless of command mode
        if verbose && (characteristic.uuid == EUS_RX || characteristic.uuid == DPS_RX || characteristic.uuid == HUB_RX) {
            let pipe = characteristic.uuid == HUB_RX ? "HUB" : characteristic.uuid == DPS_RX ? "DPS" : "EUS"
            if let pkt = G2Packet.parse(data) {
                let fields = protoDecode(pkt.payload)
                let decoded = fields.map(\.description).joined(separator: " ")
                let name = pkt.service.name.padding(toLength: 8, withPad: " ", startingAt: 0)
                log("  rx\(pipe == "DPS" ? "(DPS)" : ""): \(name) seq=\(pkt.seq) \(decoded)\n")
            } else {
                let hex = data.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                log("  rx(\(pipe)): raw \(data.count)B \(hex)\n")
            }
        }

        guard mode == .ask || mode == .dump || mode == .notify || mode == .lab || mode == .bond else { return }

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
            if mode == .lab {
                let elapsed = Date().timeIntervalSince(startTime)
                let t = String(format: "%6.2f", elapsed)
                if bytes.count >= 2 && bytes[0] == NUSResponse.gesture {
                    let g = NUSGesture(rawValue: bytes[1])
                    fputs("[\(t)] NUS  gesture    \(g?.description ?? String(format: "0x%02X", bytes[1]))\n", stderr)
                } else if bytes[0] == NUSResponse.audio {
                    audioFrames += 1
                    fputs("[\(t)] NUS  audio      frame#\(audioFrames) \(bytes.count - 2)B\n", stderr)
                } else if bytes[0] == 0x0E && bytes.count >= 3 {
                    let status = NUSMicStatus(rawValue: bytes[1])
                    fputs("[\(t)] NUS  mic-rsp    \(status?.description ?? String(format: "0x%02X", bytes[1]))\n", stderr)
                } else {
                    let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    fputs("[\(t)] NUS  raw        \(hex)\n", stderr)
                }
                return
            }
            // ask + notify: gesture detection via NUS F5
            guard bytes.count >= 2, bytes[0] == 0xF5 else { return }
            let gesture = bytes[1]
            log("  rx: NUS F5 \(String(format:"%02X", gesture)) ready=\(touchReady)\n")
            guard touchReady else { return }
            if gesture == 0x02 || gesture == 0x03 { // any slide = yes
                swipeCount += 1
                log("  NUS swipe (\(swipeCount)/2)\n")
                if swipeCount >= 2 { touched = true; disconnectAll() }
            }
            return
        }

        // DPS_RX: mic audio (205B = 5 × 40B LC3 frames + 5B trailer)
        if characteristic.uuid == DPS_RX {
            if mode == .lab && labMic {
                let elapsed = Date().timeIntervalSince(startTime)
                let t = String(format: "%6.2f", elapsed)
                if data.count == 205 {
                    for i in 0..<5 {
                        audioFrames += 1
                        let frame = data.subdata(in: (i * 40)..<((i + 1) * 40))
                        audioFileHandle?.write(frame)
                    }
                    let level = data[200]  // energy indicator byte
                    if audioFrames % 50 == 0 {
                        fputs("[\(t)] MIC  \(audioFrames) frames  level=\(level)\n", stderr)
                    }
                } else {
                    let hex = data.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                    fputs("[\(t)] DPS  \(data.count)B: \(hex)\n", stderr)
                }
            } else if mode == .dump {
                let hex = data.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                fputs("DPS  \(data.count)B: \(hex)...\n", stderr)
            }
            return
        }

        // EUS protobuf events
        guard characteristic.uuid == EUS_RX, data.count >= 10 else { return }
        let bytes = [UInt8](data)
        guard bytes[0] == 0xAA else { return }
        let svcHi = bytes[6], svcLo = bytes[7]

        if mode == .dump {
            let svc = ServiceID(hi: svcHi, lo: svcLo)
            let name = svc.name.padding(toLength: 8, withPad: " ", startingAt: 0)
            let payload = data.subdata(in: 8..<(data.count - 2))
            let fields = protoDecode(payload)
            let decoded = fields.map(\.description).joined(separator: " ")
            fputs("EUS  \(name) seq=\(bytes[2]) len=\(bytes[3])  \(decoded)\n", stderr)
            if verbose {
                let hex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                fputs("     \(hex)\n", stderr)
            }
            return
        }

        if mode == .lab {
            guard let pkt = G2Packet.parse(data) else { return }
            let msg = G2Message.parse(pkt)
            let elapsed = Date().timeIntervalSince(startTime)
            let t = String(format: "%6.2f", elapsed)
            let svc = pkt.service.name.padding(toLength: 8, withPad: " ", startingAt: 0)

            switch msg {
            case .authHeartbeatAck, .aiHeartbeatAck:
                break
            case .aiTouchEvent(_, let tt):
                fputs("[\(t)] EUS  \(svc) EVENT  \(tt?.description ?? "unknown")\n", stderr)
            case .aiState(let cmd, _, let state):
                fputs("[\(t)] EUS  \(svc) \(cmd) \(state?.description ?? "")\n", stderr)
            case .aiCompletion:
                fputs("[\(t)] EUS  \(svc) COMPLETION\n", stderr)
            case .commRsp(_, let subsys, let fields):
                let label = subsys == 8 ? "Hub" : subsys == 7 ? "AI" : "?\(subsys)"
                let d = fields.map(\.description).joined(separator: " ")
                fputs("[\(t)] EUS  \(svc) COMM_RSP(\(label)) \(d)\n", stderr)
            case .gestureStatus(let fields):
                let d = fields.map(\.description).joined(separator: " ")
                fputs("[\(t)] EUS  \(svc) gesture \(d)\n", stderr)
            case .configEvent(let f3):
                let d = f3?.map(\.description).joined(separator: " ") ?? ""
                fputs("[\(t)] EUS  \(svc) config \(d)\n", stderr)
            case .authCapability(_, let capMode):
                fputs("[\(t)] EUS  \(svc) capability mode=\(capMode)\n", stderr)
            case .unknown(_, let fields):
                let d = fields.map(\.description).joined(separator: " ")
                fputs("[\(t)] EUS  \(svc) \(d)\n", stderr)
            }
            return
        }

        // Use structured message parsing for gesture/state handling
        guard let pkt = G2Packet.parse(data) else { return }
        let msg = G2Message.parse(pkt)

        switch msg {
        // AI overlay dismissed (long-tap exit on either 07-00 or 07-01)
        case .aiState(_, _, .exit):
            guard touchReady else { break }
            log("  AI overlay dismissed\n")
            inAIMode = false
            disconnectAll()

        // AI touch events (07-01 EVENT) — 2 physical swipes = yes
        // Group rapid contacts into bursts; gap >0.4s = new swipe
        case .aiTouchEvent(_, _):
            guard touchReady else { return }
            let now = Date()
            if let last = lastContactTime, now.timeIntervalSince(last) < 0.4 {
                // Same burst — ignore
            } else {
                swipeCount += 1
                log("  EUS swipe \(swipeCount)/2\n")
            }
            lastContactTime = now
            if swipeCount >= 2 { touched = true; disconnectAll() }

        default: break
        }
    }

    // MARK: - Display



    private func sendDisplay() {
        // Clear any stale AI overlay (e.g. menu still showing from prior session)
        if mode != .dump {
            let (xs, xm) = nextId()
            writeAll(aiExit(xs, xm))
        }

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
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (qs, qm) = self.nextId()
                self.writeAll(aiQuestion(qs, qm, self.notifyTitle))
                let (rs, rm) = self.nextId()
                let reply = self.text + "\n[swipe x2 = yes | hold = dismiss]"
                self.writeAll(aiReply(rs, rm, reply))
            }
            // Drain phantom events, then arm touch detection
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
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

        if mode == .lab {
            startTime = Date()
            sent = true

            switch labDisplay {
            case "ai":
                let (es, em) = nextId()
                writeAll(aiEnter(es, em))
                inAIMode = true
                startDualHeartbeat()
                labLog("ai overlay entered")
                if !text.isEmpty {
                    Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        let (rs, rm) = self.nextId()
                        self.writeAll(aiReply(rs, rm, self.text))
                        self.labLog("reply: \(self.text)")
                    }
                }

            case "hub":
                if text.isEmpty {
                    // 0xE0-20 (EvenHub) is gated by phone app session — use AI overlay instead
                    // Enter AI mode and show a status message
                    let (es, em) = nextId()
                    writeAll(aiEnter(es, em))
                    inAIMode = true
                    startDualHeartbeat()
                    labLog("ai overlay entered (hub fallback)")
                    Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        let (rs, rm) = self.nextId()
                        self.writeAll(aiReply(rs, rm, "Hub requires phone app session. Using AI overlay."))
                        self.labLog("reply: hub status")
                    }
                } else {
                    // Teleprompter display — proven protocol from i-soxi
                    labLog("teleprompter display via EUS")
                    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                        guard let self = self else { return }
                        let (s, m) = self.nextId()
                        self.writeAll(authHeartbeat(s, m))
                    }

                    // Format text: 25 chars/line, 10 lines/page, pad to 14 pages
                    let lines = self.text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
                        .flatMap { line -> [String] in
                            let s = String(line)
                            if s.isEmpty { return [""] }
                            var chunks: [String] = []
                            var i = s.startIndex
                            while i < s.endIndex {
                                let end = s.index(i, offsetBy: 25, limitedBy: s.endIndex) ?? s.endIndex
                                chunks.append(String(s[i..<end]))
                                i = end
                            }
                            return chunks
                        }
                    let totalLines = max(lines.count, 140) // min 14 pages * 10 lines
                    var pages: [String] = []
                    for p in stride(from: 0, to: totalLines, by: 10) {
                        let pageLines = (p..<min(p+10, totalLines)).map { i in
                            i < lines.count ? lines[i] : ""
                        }
                        pages.append(pageLines.joined(separator: "\n"))
                    }

                    // 1. Display wake
                    let (ws, _) = nextId()
                    writeAll(packet(ws, 0x04, 0x20, vi(1, 1)))

                    // 2. DisplayConfig (0x0E-20) — 0.1s
                    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        let (s, m) = self.nextId()
                        let config = Data([
                            0x08, 0x01, 0x12, 0x13, 0x08, 0x02, 0x10, 0x90,
                            0x4E, 0x1D, 0x00, 0xE0, 0x94, 0x44, 0x25, 0x00,
                            0x00, 0x00, 0x00, 0x28, 0x00, 0x30, 0x00, 0x12,
                            0x13, 0x08, 0x03, 0x10, 0x0D, 0x0F, 0x1D, 0x00,
                            0x40, 0x8D, 0x44, 0x25, 0x00, 0x00, 0x00, 0x00,
                            0x28, 0x00, 0x30, 0x00, 0x12, 0x12, 0x08, 0x04,
                            0x10, 0x00, 0x1D, 0x00, 0x00, 0x88, 0x42, 0x25,
                            0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x30, 0x00,
                            0x12, 0x12, 0x08, 0x05, 0x10, 0x00, 0x1D, 0x00,
                            0x00, 0x92, 0x42, 0x25, 0x00, 0x00, 0xA2, 0x42,
                            0x28, 0x00, 0x30, 0x00, 0x12, 0x12, 0x08, 0x06,
                            0x10, 0x00, 0x1D, 0x00, 0x00, 0xC6, 0x42, 0x25,
                            0x00, 0x00, 0xC4, 0x42, 0x28, 0x00, 0x30, 0x00,
                            0x18, 0x00
                        ])
                        let payload = Data([0x08, 0x02, 0x10]) + varint(m) + Data([0x22, 0x6A]) + config
                        self.writeAll(packet(s, 0x0E, 0x20, payload))
                        self.labLog("TX  DisplayConfig")
                    }

                    // 3. Teleprompter Init (0x06-20 type=1) — 0.5s
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        let (s, m) = self.nextId()
                        let contentHeight = max(1, (totalLines * 2665) / 140)
                        var display = Data([0x08, 0x01, 0x10, 0x00, 0x18, 0x00, 0x20, 0x8B, 0x02])
                        display += Data([0x28]) + varint(contentHeight)
                        display += Data([0x30, 0xE6, 0x01, 0x38, 0x8E, 0x0A, 0x40, 0x05, 0x48, 0x00])
                        let settings = Data([0x08, 0x01, 0x12, UInt8(display.count)]) + display
                        let payload = Data([0x08, 0x01, 0x10]) + varint(m) + Data([0x1A, UInt8(settings.count)]) + settings
                        self.writeAll(packet(s, 0x06, 0x20, payload))
                        self.labLog("TX  Tele Init (\(totalLines) lines)")
                    }

                    // 4. Content pages — starting at 1.0s, 100ms apart
                    for (i, page) in pages.enumerated() {
                        let delay = 1.0 + Double(i) * 0.1
                        // Insert marker after page 9 and sync after page 11
                        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                            guard let self = self else { return }
                            let (s, m) = self.nextId()
                            let textBytes = Data([0x0A]) + Data(page.utf8) // prepend \n
                            var inner = Data([0x08]) + varint(i) + Data([0x10, 0x0A, 0x1A]) + varint(textBytes.count) + textBytes
                            let content = Data([0x2A]) + varint(inner.count) + inner
                            let payload = Data([0x08, 0x03, 0x10]) + varint(m) + content
                            self.writeAll(packet(s, 0x06, 0x20, payload))
                            if i == 0 { self.labLog("TX  page 0/\(pages.count-1)") }
                        }
                        // Marker after page 9
                        if i == 9 {
                            Timer.scheduledTimer(withTimeInterval: delay + 0.05, repeats: false) { [weak self] _ in
                                guard let self = self else { return }
                                let (s, m) = self.nextId()
                                let payload = Data([0x08, 0xFF, 0x01, 0x10]) + varint(m) + Data([0x6A, 0x04, 0x08, 0x00, 0x10, 0x06])
                                self.writeAll(packet(s, 0x06, 0x20, payload))
                                self.labLog("TX  marker")
                            }
                        }
                        // Sync after page 11
                        if i == 11 {
                            Timer.scheduledTimer(withTimeInterval: delay + 0.05, repeats: false) { [weak self] _ in
                                guard let self = self else { return }
                                let (s, m) = self.nextId()
                                let payload = Data([0x08, 0x0E, 0x10]) + varint(m) + Data([0x6A, 0x00])
                                self.writeAll(packet(s, 0x80, 0x00, payload))
                                self.labLog("TX  sync")
                            }
                        }
                    }
                    // Log completion
                    let lastPageDelay = 1.0 + Double(pages.count) * 0.1
                    Timer.scheduledTimer(withTimeInterval: lastPageDelay, repeats: false) { [weak self] _ in
                        self?.labLog("TX  all \(pages.count) pages sent")
                    }
                }

            case "nus":
                for (p, tx) in nusTxChars {
                    let payload = Data([NUSCommand.displayText]) + Data(text.utf8)
                    p.writeValue(payload, for: tx, type: .withoutResponse)
                }
                labLog("nus text: \(text)")
                heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let (s, m) = self.nextId()
                    self.writeAll(authHeartbeat(s, m))
                }

            case "conv":
                // Conversate mode — mic + display via 0x0B-20
                labLog("conversate mode")
                heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let (s, m) = self.nextId()
                    self.writeAll(authHeartbeat(s, m))
                }
                // Conversate init
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    let (s, m) = self.nextId()
                    self.writeAll(conversateInit(s, m))
                    self.inConversate = true
                    self.labLog("TX  Conversate init")
                }
                // Show text if provided
                if !text.isEmpty {
                    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        let (s, m) = self.nextId()
                        self.writeAll(conversateText(s, m, self.text))
                        self.labLog("TX  Conversate text")
                    }
                }
                // Conversate heartbeat every 10s
                Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.conversateHBTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                        guard let self = self else { return }
                        let (s, m) = self.nextId()
                        self.writeAll(conversateHeartbeat(s, m))
                    }
                }

            default:
                labLog("bare — no display")
                heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let (s, m) = self.nextId()
                    self.writeAll(authHeartbeat(s, m))
                }
            }

            if labMic {
                // Open file for raw LC3 frames (40B each, 16kHz 32kbps 10ms)
                let path = "/tmp/g2_mic.lc3"
                FileManager.default.createFile(atPath: path, contents: nil)
                audioFileHandle = FileHandle(forWritingAtPath: path)
                labLog("audio → \(path)")

                // Log MTU for each peripheral
                for p in self.peripherals {
                    let mtu = p.maximumWriteValueLength(for: .withoutResponse)
                    let side = p.name?.contains("_L_") == true ? "L" : "R"
                    labLog("MTU \(side): \(mtu + 3) (write \(mtu))")
                }

                // 1. Conversate init on EUS (0x0B-20)
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    let (s, m) = self.nextId()
                    let pkt = conversateInit(s, m)
                    self.writeAll(pkt)
                    // Also write on DPS_TX pipe
                    self.writeDPS(pkt)
                    self.inConversate = true
                    self.labLog("TX  Conversate init on EUS+DPS")
                }
                // 2. Subscribe to DPS_RX (6402) AFTER conversate init
                Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    for (p, rx) in self.dpsRxChars {
                        let props = rx.properties
                        var ps: [String] = []
                        if props.contains(.read) { ps.append("read") }
                        if props.contains(.notify) { ps.append("notify") }
                        if props.contains(.indicate) { ps.append("indicate") }
                        let side = p.name?.contains("_L_") == true ? "L" : "R"
                        self.labLog("DPS_RX \(side) props: [\(ps.joined(separator: ", "))]")
                        p.setNotifyValue(true, for: rx)
                    }
                    self.labLog("TX  subscribe DPS_RX (6402) — mic start")
                }
                // 3. Try re-subscribing at 5s (toggle off/on)
                Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    for (p, rx) in self.dpsRxChars {
                        p.setNotifyValue(false, for: rx)
                    }
                    self.labLog("DPS_RX unsubscribe")
                }
                Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    for (p, rx) in self.dpsRxChars {
                        p.setNotifyValue(true, for: rx)
                    }
                    self.labLog("DPS_RX re-subscribe")
                }
                // Conversate heartbeat every 10s
                Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.conversateHBTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                        guard let self = self else { return }
                        let (s, m) = self.nextId()
                        self.writeAll(conversateHeartbeat(s, m))
                    }
                }
            }

            let labDuration = self.timeout - 15
            labLog("listening (\(Int(labDuration))s)...")
            Timer.scheduledTimer(withTimeInterval: max(labDuration, 5), repeats: false) { [weak self] _ in
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

            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let (qs, qm) = self.nextId()
                self.writeAll(aiQuestion(qs, qm, "swipe x2=yes"))
                let (rs, rm) = self.nextId()
                self.writeAll(aiReply(rs, rm, self.text))
                self.sent = true
            }
            // Drain phantom events for 2s, then arm touch detection
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
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
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
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


    private func labLog(_ msg: String) {
        let elapsed = Date().timeIntervalSince(startTime)
        let t = String(format: "%6.2f", elapsed)
        fputs("[\(t)] \(msg)\n", stderr)
    }

    // MARK: - Bond helpers

    private func bondPropsString(_ char: CBCharacteristic) -> String {
        var p: [String] = []
        let f = char.properties
        if f.contains(.read) { p.append("read") }
        if f.contains(.write) { p.append("write") }
        if f.contains(.writeWithoutResponse) { p.append("write-nr") }
        if f.contains(.notify) { p.append("notify") }
        if f.contains(.indicate) { p.append("indicate") }
        if f.contains(.authenticatedSignedWrites) { p.append("AUTH-WRITE") }
        if f.contains(.extendedProperties) { p.append("ext") }
        if f.contains(.notifyEncryptionRequired) { p.append("NOTIFY-ENCRYPTED") }
        if f.contains(.indicateEncryptionRequired) { p.append("INDICATE-ENCRYPTED") }
        return p.joined(separator: ", ")
    }

    private func bondTryMic() {
        guard !nusTxChars.isEmpty else {
            fputs("\n--- Mic Test: no NUS TX available ---\n", stderr)
            return
        }
        fputs("\n--- Mic Test ---\n", stderr)
        for (p, tx) in nusTxChars {
            p.writeValue(Data(NUSCommand.micEnable), for: tx, type: .withoutResponse)
            fputs("  mic enable sent\n", stderr)
        }
    }

    private func bondReport() {
        fputs("\n--- Bond Summary ---\n", stderr)
        fputs("  chars discovered: \(bondCharCount)\n", stderr)
        fputs("  reads completed:  \(bondReadCount)\n", stderr)
        fputs("  (check System Settings → Bluetooth for bond status)\n", stderr)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if mode == .bond {
            if let err = error as NSError?, err.domain == CBATTErrorDomain && (err.code == 5 || err.code == 15) {
                fputs("    → \(characteristic.uuid): *** NOTIFY REQUIRES ENCRYPTION — pairing initiated ***\n", stderr)
            } else if let error = error {
                fputs("    → \(characteristic.uuid): notify error: \(error.localizedDescription)\n", stderr)
            }
        }
        // Log DPS_RX (mic) subscription result
        if characteristic.uuid == DPS_RX {
            let side = peripheral.name?.contains("_L_") == true ? "L" : "R"
            if let error = error {
                labLog("DPS_RX \(side) notify ERROR: \(error.localizedDescription)")
            } else {
                labLog("DPS_RX \(side) notify \(characteristic.isNotifying ? "ON" : "OFF")")
            }
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
        conversateHBTimer?.invalidate()
        if inConversate {
            let (cs, cm) = nextId()
            writeAll(conversateStop(cs, cm))
        }
        if inAIMode {
            let (s, m) = nextId()
            writeAll(aiExit(s, m))
        }
        if let fh = audioFileHandle {
            fh.closeFile()
            audioFileHandle = nil
            if audioFrames > 0 {
                let seconds = Double(audioFrames) * 0.01  // 10ms per frame
                fputs("Recorded \(audioFrames) frames (\(String(format: "%.1f", seconds))s) → /tmp/g2_mic.lc3\n", stderr)
            }
        }
        // Brief delay to let exit packet flush before disconnect
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            for p in self.peripherals { self.central.cancelPeripheralConnection(p) }
            self.done = true
        }
    }
}
