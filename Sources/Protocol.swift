import Foundation

// MARK: - BLE Services

/// Even G2 BLE service and characteristic UUIDs
enum G2Service {
    /// Even UART Service — authenticated protobuf protocol
    static let eus        = "00002760-08C2-11E1-9073-0E8AC72E5450"
    static let eusTX      = "00002760-08C2-11E1-9073-0E8AC72E5401"
    static let eusRX      = "00002760-08C2-11E1-9073-0E8AC72E5402"

    /// Display sensor stream (205B @ 18.8Hz)
    static let displayTX  = "00002760-08C2-11E1-9073-0E8AC72E6401"
    static let displayRX  = "00002760-08C2-11E1-9073-0E8AC72E6402"

    /// File transfer (notifications, maps, firmware)
    static let fileTX     = "00002760-08C2-11E1-9073-0E8AC72E7401"
    static let fileRX     = "00002760-08C2-11E1-9073-0E8AC72E7402"

    /// Nordic UART Service — raw commands, gestures, audio
    static let nus        = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusTX      = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusRX      = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
}

// MARK: - Packet Framing

/// G2 packet envelope: AA-21 header + protobuf payload + CRC16
struct G2Packet {
    static let magic: UInt8 = 0xAA
    static let typeCommand: UInt8 = 0x21   // phone → glasses
    static let typeResponse: UInt8 = 0x12  // glasses → phone

    let seq: UInt8
    let service: ServiceID
    let payload: Data

    /// Parse a raw EUS RX notification into a G2Packet
    static func parse(_ data: Data) -> G2Packet? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] == magic else { return nil }
        let svc = ServiceID(hi: b[6], lo: b[7])
        let payload = data.subdata(in: 8..<(data.count - 2))
        return G2Packet(seq: b[2], service: svc, payload: payload)
    }
}

// MARK: - Service IDs

/// Two-byte service identifier (svcHi-svcLo)
struct ServiceID: Hashable, CustomStringConvertible {
    let hi: UInt8
    let lo: UInt8

    var description: String { String(format: "%02X-%02X", hi, lo) }

    // Direction convention: -00/-01 = response, -20 = command

    // Authentication
    static let authControl     = ServiceID(hi: 0x80, lo: 0x00)  // TX + RX
    static let authData        = ServiceID(hi: 0x80, lo: 0x20)  // TX
    static let authResponse    = ServiceID(hi: 0x80, lo: 0x01)  // RX
    static let transportAck    = ServiceID(hi: 0x80, lo: 0x02)  // RX

    // Dashboard & Gestures
    static let dashboard       = ServiceID(hi: 0x01, lo: 0x20)  // TX
    static let gestureStatus   = ServiceID(hi: 0x01, lo: 0x01)  // RX

    // Notifications
    static let notification    = ServiceID(hi: 0x02, lo: 0x20)  // TX
    static let notificationRsp = ServiceID(hi: 0x02, lo: 0x00)  // RX

    // Menu
    static let menu            = ServiceID(hi: 0x03, lo: 0x20)

    // Display
    static let displayWake     = ServiceID(hi: 0x04, lo: 0x20)  // TX
    static let displayWakeRsp  = ServiceID(hi: 0x04, lo: 0x00)  // RX
    static let deviceInfoRsp   = ServiceID(hi: 0x04, lo: 0x01)  // RX

    // Translation
    static let translate       = ServiceID(hi: 0x05, lo: 0x20)

    // Teleprompter
    static let teleprompter    = ServiceID(hi: 0x06, lo: 0x20)  // TX
    static let teleprompterAck = ServiceID(hi: 0x06, lo: 0x00)  // RX
    static let teleprompterPrg = ServiceID(hi: 0x06, lo: 0x01)  // RX

    // AI Overlay
    static let ai              = ServiceID(hi: 0x07, lo: 0x20)  // TX
    static let aiResponse      = ServiceID(hi: 0x07, lo: 0x00)  // RX
    static let aiStatus        = ServiceID(hi: 0x07, lo: 0x01)  // RX

    // Navigation
    static let navigation      = ServiceID(hi: 0x08, lo: 0x20)

    // Device Info
    static let deviceInfo      = ServiceID(hi: 0x09, lo: 0x00)
    static let deviceInfoRsp2  = ServiceID(hi: 0x09, lo: 0x01)  // RX

    // Session
    static let sessionInit     = ServiceID(hi: 0x0A, lo: 0x20)  // TX

    // Speech-to-Text
    static let conversate      = ServiceID(hi: 0x0B, lo: 0x20)  // TX
    static let conversateAck   = ServiceID(hi: 0x0B, lo: 0x00)  // RX
    static let conversateNotif = ServiceID(hi: 0x0B, lo: 0x01)  // RX

    // Quicklist + Health
    static let quicklistHealth = ServiceID(hi: 0x0C, lo: 0x20)

    // Configuration
    static let config          = ServiceID(hi: 0x0D, lo: 0x00)  // TX + RX
    static let configEvents    = ServiceID(hi: 0x0D, lo: 0x01)  // RX
    static let deviceConfig    = ServiceID(hi: 0x0D, lo: 0x20)  // TX

    // Display Config
    static let displayConfig   = ServiceID(hi: 0x0E, lo: 0x20)  // TX

    // Logger
    static let logger          = ServiceID(hi: 0x0F, lo: 0x20)

    // Onboarding
    static let onboarding      = ServiceID(hi: 0x10, lo: 0x20)

    // Module Config
    static let moduleConfigure = ServiceID(hi: 0x20, lo: 0x20)

    // System
    static let systemAlert     = ServiceID(hi: 0x21, lo: 0x20)  // RX
    static let systemClose     = ServiceID(hi: 0x22, lo: 0x20)

    // Peripherals
    static let glassesCase     = ServiceID(hi: 0x81, lo: 0x20)
    static let ringRelay       = ServiceID(hi: 0x91, lo: 0x20)

    // File Transfer
    static let fileCommand     = ServiceID(hi: 0xC4, lo: 0x00)
    static let fileData        = ServiceID(hi: 0xC5, lo: 0x00)

    // EvenHub
    static let evenHub         = ServiceID(hi: 0xE0, lo: 0x20)
    static let evenHubResponse = ServiceID(hi: 0xE0, lo: 0x00)

    // System Monitor
    static let systemMonitor   = ServiceID(hi: 0xFF, lo: 0x20)  // RX

    /// Short name for log output
    var name: String {
        switch (hi, lo) {
        case (0x80, 0x00): return "Auth"
        case (0x80, 0x20): return "AuthDat"
        case (0x80, 0x01): return "AuthRsp"
        case (0x80, 0x02): return "AuthACK"
        case (0x01, 0x20): return "Dash"
        case (0x01, 0x01): return "Gesture"
        case (0x02, 0x20): return "Notif"
        case (0x02, 0x00): return "NotifRsp"
        case (0x03, 0x20): return "Menu"
        case (0x04, 0x20): return "DspWake"
        case (0x04, 0x00): return "DspWkRsp"
        case (0x04, 0x01): return "DevInfo"
        case (0x05, 0x20): return "Xlate"
        case (0x06, 0x20): return "Tele"
        case (0x06, 0x00): return "TeleACK"
        case (0x06, 0x01): return "TeleProg"
        case (0x07, 0x20): return "AI"
        case (0x07, 0x00): return "AIRsp"
        case (0x07, 0x01): return "AIStat"
        case (0x08, 0x20): return "Nav"
        case (0x09, 0x00): return "DevInfo"
        case (0x09, 0x01): return "DevInRsp"
        case (0x0A, 0x20): return "SessInit"
        case (0x0B, 0x20): return "Conv"
        case (0x0B, 0x00): return "ConvACK"
        case (0x0B, 0x01): return "ConvNtfy"
        case (0x0C, 0x20): return "QkHealth"
        case (0x0D, 0x00): return "Config"
        case (0x0D, 0x01): return "CfgEvt"
        case (0x0D, 0x20): return "DevCfg"
        case (0x0E, 0x20): return "DspCfg"
        case (0x0F, 0x20): return "Logger"
        case (0x10, 0x20): return "Onboard"
        case (0x20, 0x20): return "ModCfg"
        case (0x21, 0x20): return "SysAlert"
        case (0x22, 0x20): return "SysClose"
        case (0x81, 0x20): return "Case"
        case (0x91, 0x20): return "Ring"
        case (0xC4, 0x00): return "FileCmd"
        case (0xC5, 0x00): return "FileData"
        case (0xE0, 0x20): return "Hub"
        case (0xE0, 0x00): return "HubRsp"
        case (0xFF, 0x20): return "SysMon"
        default:           return description
        }
    }
}

// MARK: - AI Overlay Protocol (0x07)

/// AI overlay command types (f1 field)
enum AICommand: UInt8, CustomStringConvertible {
    case none       = 0
    case ctrl       = 1   // enter/exit AI mode
    case vadInfo    = 2   // voice activity detection
    case ask        = 3   // send question
    case analyse    = 4   // send analysis request
    case reply      = 5   // send AI response
    case skill      = 6   // activate skill
    case prompt     = 7   // send prompt text
    case event      = 8   // event notification (touches)
    case heartbeat  = 9   // AI keepalive
    case config     = 10  // stream speed, text mode
    case completion = 161 // display render completion

    var description: String {
        switch self {
        case .none:       return "NONE"
        case .ctrl:       return "CTRL"
        case .vadInfo:    return "VAD"
        case .ask:        return "ASK"
        case .analyse:    return "ANALYSE"
        case .reply:      return "REPLY"
        case .skill:      return "SKILL"
        case .prompt:     return "PROMPT"
        case .event:      return "EVENT"
        case .heartbeat:  return "HEARTBEAT"
        case .config:     return "CONFIG"
        case .completion: return "COMPLETION"
        }
    }
}

/// AI overlay state transitions (f3.f1 in CTRL messages)
enum AIState: UInt8, CustomStringConvertible {
    case unknown  = 0
    case wakeUp   = 1
    case enter    = 2
    case exit     = 3

    var description: String {
        switch self {
        case .unknown: return "unknown"
        case .wakeUp:  return "wake_up"
        case .enter:   return "enter"
        case .exit:    return "exit"
        }
    }
}

/// AI skill indices (used with AICommand.skill)
enum AISkill: UInt8, CustomStringConvertible {
    case brightness     = 0
    case translate      = 1
    case notification   = 2
    case teleprompter   = 3
    case navigate       = 4
    case conversate     = 5
    case quicklist      = 6
    case autoBrightness = 7

    var description: String {
        switch self {
        case .brightness:     return "brightness"
        case .translate:      return "translate"
        case .notification:   return "notification"
        case .teleprompter:   return "teleprompter"
        case .navigate:       return "navigate"
        case .conversate:     return "conversate"
        case .quicklist:      return "quicklist"
        case .autoBrightness: return "auto_brightness"
        }
    }
}

// MARK: - Auth Protocol (0x80)

/// Auth message types (f1 field on 0x80-xx)
enum AuthType: UInt8, CustomStringConvertible {
    case capability         = 4   // query/response capability
    case capabilityResponse = 5   // capability data
    case heartbeat          = 14  // auth keepalive (0x0E) — ONLY safe type
    case timeSync           = 128 // 0x80, clock synchronization

    var description: String {
        switch self {
        case .capability:         return "CAPABILITY"
        case .capabilityResponse: return "CAPABILITY_RSP"
        case .heartbeat:          return "HEARTBEAT"
        case .timeSync:           return "TIME_SYNC"
        }
    }
}

// MARK: - Gesture Protocol

/// NUS gesture codes (0xF5 prefix, second byte)
enum NUSGesture: UInt8, CustomStringConvertible {
    case doubleTap    = 0x00
    case tap          = 0x01
    case slideFwd     = 0x02
    case slideBack    = 0x03
    case tripleTapL   = 0x04
    case tripleTapR   = 0x05
    case longPress    = 0x17
    case release      = 0x24

    var description: String {
        switch self {
        case .doubleTap:  return "double_tap"
        case .tap:        return "tap"
        case .slideFwd:   return "slide_fwd"
        case .slideBack:  return "slide_back"
        case .tripleTapL: return "triple_tap_L"
        case .tripleTapR: return "triple_tap_R"
        case .longPress:  return "long_press"
        case .release:    return "release"
        }
    }
}

/// EUS touch types (f10.f1 in AI EVENT messages on 0x07-01)
enum EUSTouchType: UInt8, CustomStringConvertible {
    case contact   = 1  // single touch contact point
    case slideFwd  = 2  // firmware-classified slide forward
    case slideBack = 3  // firmware-classified slide backward

    var description: String {
        switch self {
        case .contact:   return "contact"
        case .slideFwd:  return "slide_fwd"
        case .slideBack: return "slide_back"
        }
    }
}

// MARK: - Display Modes

/// Display mode values (f3.f1 on 0x80-01 auth response)
enum DisplayMode: UInt8, CustomStringConvertible {
    case auth         = 1   // connected, idle
    case render       = 6   // actively rendering
    case conversate   = 11  // speech-to-text mode
    case teleprompter = 16  // teleprompter mode

    var description: String {
        switch self {
        case .auth:         return "auth"
        case .render:       return "render"
        case .conversate:   return "conversate"
        case .teleprompter: return "teleprompter"
        }
    }
}

// MARK: - NUS Commands

/// NUS TX command prefixes (phone → glasses)
enum NUSCommand {
    static let heartbeat: [UInt8]   = [0x25]
    static let micEnable: [UInt8]   = [0x0E, 0x01]
    static let micDisable: [UInt8]  = [0x0E, 0x00]
    static let displayText: UInt8   = 0x4E  // followed by UTF-8
    static let displayBMP: UInt8    = 0x15  // followed by BMP data (576×288)
    static let initHandshake: [UInt8] = [0x4D, 0x01]
}

/// NUS RX response prefixes (glasses → phone)
enum NUSResponse {
    static let gesture: UInt8 = 0xF5  // followed by gesture code
    static let audio: UInt8   = 0xF1  // followed by LC3 audio frame
}

/// NUS microphone response status (in [0x0E, status, enable] response)
enum NUSMicStatus: UInt8, CustomStringConvertible {
    case success = 0xC9
    case failure = 0xCA

    var description: String {
        switch self {
        case .success: return "OK"
        case .failure: return "FAIL"
        }
    }
}

// MARK: - EvenHub (0x07, types 11-19)

/// EvenHub error/result codes from COMM_RSP responses
enum HubErrorCode: Int, CustomStringConvertible {
    case createPageSuccess       = 0
    case createInvalidContainer  = 1
    case createOversizeContainer = 2
    case createOutOfMemory       = 3
    case imageDataSuccess        = 4
    case imageDataFailed         = 5
    case rebuildPageSuccess      = 6
    case rebuildPageFailed       = 7
    case textDataSuccess         = 8
    case textDataFailed          = 9
    case shutdownSuccess         = 10
    case shutdownFailed          = 11
    case heartbeatSuccess        = 12

    var description: String {
        switch self {
        case .createPageSuccess:       return "CREATE_PAGE_OK"
        case .createInvalidContainer:  return "CREATE_INVALID"
        case .createOversizeContainer: return "CREATE_OVERSIZE"
        case .createOutOfMemory:       return "CREATE_OOM"
        case .imageDataSuccess:        return "IMAGE_OK"
        case .imageDataFailed:         return "IMAGE_FAIL"
        case .rebuildPageSuccess:      return "REBUILD_OK"
        case .rebuildPageFailed:       return "REBUILD_FAIL"
        case .textDataSuccess:         return "TEXT_OK"
        case .textDataFailed:          return "TEXT_FAIL"
        case .shutdownSuccess:         return "SHUTDOWN_OK"
        case .shutdownFailed:          return "SHUTDOWN_FAIL"
        case .heartbeatSuccess:        return "HB_OK"
        }
    }
}

// MARK: - Ring Relay (0x91)

/// R1 ring gesture bytes forwarded through glasses
enum RingGesture {
    static let tap: [UInt8]      = [0xFF, 0x04, 0x01]
    static let doubleTap: [UInt8] = [0xFF, 0x04, 0x02]
    static let swipeFwd: [UInt8]  = [0xFF, 0x05, 0x00]
    static let swipeBack: [UInt8] = [0xFF, 0x05, 0x02]
    static let hold: [UInt8]      = [0xFF, 0x03, 0x20]
}

// MARK: - File Transfer (0xC4/0xC5)

/// File transfer command bytes on 0xC4-00
enum FileTransferOp: UInt8, CustomStringConvertible {
    case start    = 0x01
    case end      = 0x02

    var description: String {
        switch self {
        case .start: return "START"
        case .end:   return "END"
        }
    }
}

/// File transfer response status (2-byte LE on 0x7402)
enum FileTransferStatus: UInt16, CustomStringConvertible {
    case fileOpened  = 0x0000
    case dataRecvd   = 0x0001  // 0x0100 LE → 0x0001
    case complete    = 0x0002  // 0x0200 LE → 0x0002

    var description: String {
        switch self {
        case .fileOpened: return "FILE_OPENED"
        case .dataRecvd:  return "DATA_RECEIVED"
        case .complete:   return "COMPLETE"
        }
    }
}

// MARK: - Protobuf Decoding

/// Decoded protobuf field
struct ProtoField: CustomStringConvertible {
    let number: Int
    let wire: Int  // 0=varint, 2=length-delimited
    let varint: Int?
    let bytes: Data?
    let nested: [ProtoField]?

    var description: String {
        if let v = varint { return "f\(number)=\(v)" }
        if let n = nested, !n.isEmpty {
            let inner = n.map(\.description).joined(separator: " ")
            return "f\(number)={\(inner)}"
        }
        if let b = bytes {
            let hex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
            return "f\(number)=[\(hex)]"
        }
        return "f\(number)=?"
    }

    /// Get a nested field by number
    func sub(_ field: Int) -> ProtoField? {
        nested?.first(where: { $0.number == field })
    }

    /// Get varint value, checking nested if needed
    var intValue: Int? { varint }
}

/// Decode protobuf fields from raw bytes
func protoDecode(_ data: Data) -> [ProtoField] {
    var fields: [ProtoField] = []
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        guard i < bytes.count else { break }
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
            fields.append(ProtoField(number: field, wire: 0, varint: v, bytes: nil, nested: nil))
        case 2: // length-delimited
            var len = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]); i += 1
                len |= (b & 0x7F) << shift; shift += 7
                if b & 0x80 == 0 { break }
            }
            let end = min(i + len, bytes.count)
            let sub = Data(bytes[i..<end])
            let nested = protoDecode(sub)
            if !nested.isEmpty && nested.allSatisfy({ $0.number > 0 && $0.number < 200 }) {
                fields.append(ProtoField(number: field, wire: 2, varint: nil, bytes: sub, nested: nested))
            } else {
                fields.append(ProtoField(number: field, wire: 2, varint: nil, bytes: sub, nested: nil))
            }
            i = end
        default:
            break
        }
    }
    return fields
}

// MARK: - Structured Message Decode

/// Parsed G2 message with semantic meaning
enum G2Message {
    case authHeartbeatAck(msgId: Int)
    case authCapability(msgId: Int, mode: Int)
    case aiState(command: AICommand, msgId: Int, state: AIState?)
    case aiHeartbeatAck(msgId: Int)
    case aiCompletion(msgId: Int)
    case aiTouchEvent(msgId: Int, touchType: EUSTouchType?)
    case commRsp(msgId: Int, subsystem: Int, fields: [ProtoField])
    case configEvent(field3: [ProtoField]?)
    case gestureStatus(fields: [ProtoField])
    case unknown(service: ServiceID, fields: [ProtoField])

    /// Parse a G2Packet into a semantic message
    static func parse(_ pkt: G2Packet) -> G2Message {
        let fields = protoDecode(pkt.payload)
        let f1 = fields.first(where: { $0.number == 1 })?.varint
        let f2 = fields.first(where: { $0.number == 2 })?.varint

        switch pkt.service {
        // Auth responses
        case .authControl where f1 == 14:
            return .authHeartbeatAck(msgId: f2 ?? 0)
        case .authResponse:
            let mode = fields.first(where: { $0.number == 3 })?.sub(1)?.varint
            return .authCapability(msgId: f2 ?? 0, mode: mode ?? 0)

        // AI responses (0x07-00)
        case .aiResponse:
            // COMM_RSP: f12 present with subsystem indicator (f12.f1=7 AI, f12.f1=8 Hub)
            if let f12 = fields.first(where: { $0.number == 12 }),
               let subsys = f12.sub(1)?.intValue {
                return .commRsp(msgId: f2 ?? 0, subsystem: subsys, fields: fields)
            }
            guard let cmd = f1.flatMap({ AICommand(rawValue: UInt8($0)) }) else {
                return .unknown(service: pkt.service, fields: fields)
            }
            switch cmd {
            case .ctrl:
                let state = fields.first(where: { $0.number == 3 })?.sub(1)?.varint
                    .flatMap { AIState(rawValue: UInt8($0)) }
                return .aiState(command: cmd, msgId: f2 ?? 0, state: state)
            case .heartbeat:
                return .aiHeartbeatAck(msgId: f2 ?? 0)
            case .completion:
                return .aiCompletion(msgId: f2 ?? 0)
            default:
                return .aiState(command: cmd, msgId: f2 ?? 0, state: nil)
            }

        // AI status (0x07-01) — touch events + exit signals
        case .aiStatus:
            guard let cmd = f1.flatMap({ AICommand(rawValue: UInt8($0)) }) else {
                return .unknown(service: pkt.service, fields: fields)
            }
            if cmd == .event {
                let tt = fields.first(where: { $0.number == 10 })?.sub(1)?.varint
                    .flatMap { EUSTouchType(rawValue: UInt8($0)) }
                return .aiTouchEvent(msgId: f2 ?? 0, touchType: tt)
            }
            if cmd == .ctrl {
                let state = fields.first(where: { $0.number == 3 })?.sub(1)?.varint
                    .flatMap { AIState(rawValue: UInt8($0)) }
                return .aiState(command: cmd, msgId: f2 ?? 0, state: state)
            }
            return .unknown(service: pkt.service, fields: fields)

        // Config events (0x0D-01)
        case .configEvents:
            let f3 = fields.first(where: { $0.number == 3 })?.nested
            return .configEvent(field3: f3)

        // Dashboard gestures (0x01-01)
        case .gestureStatus:
            return .gestureStatus(fields: fields)

        default:
            return .unknown(service: pkt.service, fields: fields)
        }
    }
}
