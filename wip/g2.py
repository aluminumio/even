#!/usr/bin/env python3
"""Even G2 glasses driver — connect from Mac, drive all features.

Usage:
    python g2.py ai "What is 2+2?" "The answer is 4!"
    python g2.py teleprompter "Your text here with\nmultiple lines"
    python g2.py nav "Turn left" "100 m" --eta "13:07" --speed "5 km/h"
    python g2.py conversate "Hello world" "This is live" "transcription"
    python g2.py text "Quick NUS text"
    python g2.py voice              # record from Mac mic, transcribe, show on glasses
    python g2.py dash
"""
import asyncio, sys, time, argparse
from bleak import BleakClient, BleakScanner

UUID_BASE = "00002760-08c2-11e1-9073-0e8ac72e{:04x}"
EUS_TX = UUID_BASE.format(0x5401)
EUS_RX = UUID_BASE.format(0x5402)
NUS_TX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

# ── Primitives ──

def crc16(data, init=0xFFFF):
    crc = init
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc

def varint(v):
    r = []
    while v > 0x7F:
        r.append((v & 0x7F) | 0x80)
        v >>= 7
    r.append(v & 0x7F)
    return bytes(r)

def ld(field_num, data):
    """Protobuf length-delimited field."""
    return bytes([field_num << 3 | 2]) + varint(len(data)) + data

def vi(field_num, value):
    """Protobuf varint field."""
    return bytes([field_num << 3]) + varint(value)

def packet(seq, svc_hi, svc_lo, payload):
    hdr = bytes([0xAA, 0x21, seq, len(payload) + 2, 0x01, 0x01, svc_hi, svc_lo])
    c = crc16(payload)
    return hdr + payload + bytes([c & 0xFF, (c >> 8) & 0xFF])

def hexstr(d): return " ".join(f"{b:02x}" for b in d)

# ── Auth ──

def auth_packets():
    ts = varint(int(time.time()))
    txid = bytes([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    sync = lambda s, m: vi(1, 128) + vi(2, m) + ld(16, b'\x08' + ts + b'\x10' + txid)
    return [
        packet(1, 0x80, 0x00, vi(1,4) + vi(2,0x0C) + ld(3, vi(1,1) + vi(2,4))),
        packet(2, 0x80, 0x20, vi(1,5) + vi(2,0x0E) + ld(4, vi(1,2))),
        packet(3, 0x80, 0x20, sync(3, 0x0F)),
        packet(4, 0x80, 0x00, vi(1,4) + vi(2,0x10) + ld(3, vi(1,1) + vi(2,4))),
        packet(5, 0x80, 0x00, vi(1,4) + vi(2,0x11) + ld(3, vi(1,1) + vi(2,4))),
        packet(6, 0x80, 0x20, vi(1,5) + vi(2,0x12) + ld(4, vi(1,1))),
        packet(7, 0x80, 0x20, sync(7, 0x13)),
    ]

# ── Even AI (0x07-20) ──

def ai_ctrl_enter(seq, mid):
    return packet(seq, 0x07, 0x20, vi(1,1) + vi(2,mid) + ld(3, vi(1,2)))

def ai_ctrl_exit(seq, mid):
    return packet(seq, 0x07, 0x20, vi(1,1) + vi(2,mid) + ld(3, vi(1,3)))

def ai_ask(seq, mid, text):
    info = vi(1,0) + vi(2,0) + vi(3,0) + ld(4, text.encode())
    return packet(seq, 0x07, 0x20, vi(1,3) + vi(2,mid) + ld(5, info))

def ai_reply(seq, mid, text):
    info = vi(1,0) + vi(2,0) + vi(3,0) + ld(4, text.encode())
    return packet(seq, 0x07, 0x20, vi(1,5) + vi(2,mid) + ld(7, info))

# ── Navigation (0x08-20) ──

def nav_update(seq, mid, instruction, distance, time_remaining="", total_dist="", eta="", speed="", icon=3):
    inner = vi(1, 4)
    inner += ld(2, distance.encode())
    inner += ld(3, instruction.encode())
    if time_remaining: inner += ld(4, time_remaining.encode())
    if total_dist:     inner += ld(5, total_dist.encode())
    if eta:            inner += ld(6, eta.encode())
    if speed:          inner += ld(7, speed.encode())
    inner += vi(8, icon)
    return packet(seq, 0x08, 0x20, vi(1, 7) + vi(2, mid) + ld(5, inner))

def nav_start(seq, mid):
    return packet(seq, 0x08, 0x20, vi(1, 7) + vi(2, mid) + ld(5, vi(1, 1)))

def nav_stop(seq, mid):
    return packet(seq, 0x08, 0x20, vi(1, 8) + vi(2, mid))

# ── Conversate (0x0B-20) ──

def conv_init1(seq):
    payload = bytes.fromhex("080110351A1008011210080110011800200128001800")
    return packet(seq, 0x0B, 0x20, payload)

def conv_init2(seq):
    payload = bytes.fromhex("08FF0110385200")
    return packet(seq, 0x0B, 0x20, payload)

def conv_text(seq, update_id, text, final=False):
    padded = text.encode()[:30].ljust(30)
    inner = ld(1, padded) + vi(2, 1 if final else 0)
    return packet(seq, 0x0B, 0x20, vi(1, 5) + vi(2, update_id) + ld(7, inner))

# ── Teleprompter (0x06-20) ──

def tp_display_config(seq, mid):
    config = bytes.fromhex(
        "080112130802109040" if False else  # placeholder
        "0801121308021090"
        "4E1D00E094442500"
        "000000280030001213"
        "0803100D0F1D0040"
        "8D44250000000028"
        "0030001212080410"
        "001D0000884225"
        "00000000280030"
        "001212080510001D"
        "00009242250000"
        "A242280030001212"
        "080610001D0000C6"
        "42250000C4422800"
        "30001800"
    )
    return packet(seq, 0x0E, 0x20, vi(1,2) + vi(2,mid) + ld(4, config))

def tp_init(seq, mid, total_lines=10, manual=True):
    h = max(1, (total_lines * 2665) // 140)
    display = (vi(1,1) + vi(2,0) + vi(3,0) + varint(0x20) + bytes([0x8b, 0x02]) +
               bytes([0x28]) + varint(h) + bytes([0x30, 0xE6, 0x01, 0x38, 0x8E, 0x0A,
               0x40, 0x05, 0x48, 0x00 if manual else 0x01]))
    settings = vi(1,1) + ld(2, display)
    return packet(seq, 0x06, 0x20, vi(1,1) + vi(2,mid) + ld(3, settings))

def tp_page(seq, mid, page_num, text):
    text_bytes = ("\n" + text).encode()
    inner = vi(1, page_num) + vi(2, 10) + ld(3, text_bytes)
    return packet(seq, 0x06, 0x20, vi(1,3) + vi(2,mid) + ld(5, inner))

def tp_marker(seq, mid):
    return packet(seq, 0x06, 0x20,
        bytes([0x08, 0xFF, 0x01, 0x10]) + varint(mid) + bytes([0x6A, 0x04, 0x08, 0x00, 0x10, 0x06]))

def tp_sync(seq, mid):
    return packet(seq, 0x80, 0x00, vi(1, 0x0E) + vi(2, mid) + ld(13, b''))

def format_pages(text, cpl=25, lpp=10):
    text = text.replace("\\n", "\n")
    wrapped = []
    for line in text.split("\n"):
        if not line.strip():
            wrapped.append("")
            continue
        words, cur = line.split(), ""
        for w in words:
            if len(cur) + len(w) + 1 > cpl:
                if cur: wrapped.append(cur.strip())
                cur = w + " "
            else: cur += w + " "
        if cur.strip(): wrapped.append(cur.strip())
    if not wrapped: wrapped = [text]
    while len(wrapped) < lpp: wrapped.append(" ")
    pages = []
    for i in range(0, len(wrapped), lpp):
        p = wrapped[i:i+lpp]
        while len(p) < lpp: p.append(" ")
        pages.append("\n".join(p) + " \n")
    while len(pages) < 14:
        pages.append("\n".join([" "] * lpp) + " \n")
    return pages

# ── Heartbeat ──

def display_wake(seq, mid):
    inner = vi(1,1) + vi(2,1) + vi(3,5) + vi(5,1)
    return packet(seq, 0x04, 0x20, vi(1, 1) + vi(2, mid) + ld(3, inner))

def heartbeat(seq, mid):
    return packet(seq, 0x80, 0x00, vi(1, 0x0E) + vi(2, mid) + ld(13, b''))

# ── Connection ──

async def connect_glasses(both=True):
    """Scan and connect to G2 glasses. Returns {side: (client, label)}."""
    print("Scanning...")
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)
    targets = {}
    for d, adv in devices.values():
        if d.name and "G2" in d.name:
            side = "L" if "_L_" in d.name else "R" if "_R_" in d.name else "?"
            targets[side] = d
            print(f"  {side}: {d.name} (RSSI {adv.rssi})")
    if not targets:
        print("No G2 found!")
        return {}
    if not both:
        # Prefer left for display features
        key = "L" if "L" in targets else list(targets.keys())[0]
        targets = {key: targets[key]}
    clients = {}
    for side, dev in targets.items():
        c = BleakClient(dev)
        await c.connect()
        await c.start_notify(EUS_RX, lambda s, d: None)
        try: await c.start_notify(NUS_RX, lambda s, d: None)
        except: pass
        for pkt in auth_packets():
            await c.write_gatt_char(EUS_TX, pkt, response=False)
            await asyncio.sleep(0.1)
        await asyncio.sleep(0.5)
        clients[side] = c
        print(f"  {side} authenticated")
    return clients

async def with_glasses(fn, both=True, keepalive=5):
    """Connect, run fn(clients, Sequencer), keepalive, disconnect."""
    clients = await connect_glasses(both)
    if not clients: return

    class Seq:
        def __init__(self): self.seq, self.mid = 0x08, 0x14
        def next(self):
            s, m = self.seq, self.mid
            self.seq += 1; self.mid += 1
            return s, m

    s = Seq()
    await fn(clients, s)

    # Keepalive
    for _ in range(keepalive):
        await asyncio.sleep(2)
        for c in clients.values():
            seq, mid = s.next()
            await c.write_gatt_char(EUS_TX, heartbeat(seq, mid), response=False)

    for c in clients.values():
        await c.disconnect()
    print("Done.")

async def send_all(clients, pkt_or_fn, s=None):
    """Send a packet to all connected eyes."""
    for c in clients.values():
        p = pkt_or_fn(s) if callable(pkt_or_fn) else pkt_or_fn
        await c.write_gatt_char(EUS_TX, p, response=False)
    await asyncio.sleep(0.1)

# ── Commands ──

async def cmd_ai(args):
    async def run(clients, s):
        # Enter AI mode
        seq, mid = s.next()
        await send_all(clients, ai_ctrl_enter(seq, mid))
        await asyncio.sleep(0.3)
        # Send question (skip if empty)
        if args.question:
            seq, mid = s.next()
            await send_all(clients, ai_ask(seq, mid, args.question))
            print(f"  Q: {args.question}")
            await asyncio.sleep(1.0)
        # Stream answer word by word — each REPLY appends to display
        words = args.answer.split()
        for word in words:
            seq, mid = s.next()
            for c in clients.values():
                await c.write_gatt_char(EUS_TX, ai_reply(seq, mid, word + " "), response=False)
            await asyncio.sleep(0.15)
        print(f"  A: {args.answer}")
    await with_glasses(run, both=False, keepalive=args.keepalive)

async def cmd_nav(args):
    icon_map = {"left": "\u2190", "right": "\u2192", "straight": "\u2191", "uturn": "\u21B6"}
    arrow = icon_map.get(args.icon, "\u2191")
    async def run(clients, s):
        # Use Even AI display path (native nav handler is firmware-guarded)
        seq, mid = s.next()
        await send_all(clients, ai_ctrl_enter(seq, mid))
        await asyncio.sleep(0.3)
        # Show instruction as question
        question = f"{arrow} {args.instruction}"
        seq, mid = s.next()
        await send_all(clients, ai_ask(seq, mid, question))
        await asyncio.sleep(0.5)
        # Show distance + details as answer
        parts = [args.distance]
        if args.eta: parts.append(args.eta)
        if args.speed: parts.append(args.speed)
        if args.time: parts.append(args.time)
        answer = " | ".join(parts)
        seq, mid = s.next()
        await send_all(clients, ai_reply(seq, mid, answer))
        print(f"  Nav: {arrow} {args.instruction} — {answer}")
    await with_glasses(run, both=False, keepalive=args.keepalive)

async def cmd_conversate(args):
    async def run(clients, s):
        seq, _ = s.next()
        await send_all(clients, conv_init1(seq))
        await asyncio.sleep(0.6)
        seq, _ = s.next()
        await send_all(clients, conv_init2(seq))
        await asyncio.sleep(0.6)
        uid = 0x41
        for i, text in enumerate(args.texts):
            final = (i == len(args.texts) - 1)
            seq, _ = s.next()
            await send_all(clients, conv_text(seq, uid, text, final=final))
            print(f"  {'*' if final else '~'} {text}")
            uid += 1
            await asyncio.sleep(0.6)
    await with_glasses(run, both=False, keepalive=args.keepalive)

async def cmd_teleprompter(args):
    async def run(clients, s):
        pages = format_pages(args.text)
        total_lines = len(args.text.replace("\\n", "\n").split("\n"))
        # Display config (required for teleprompter)
        seq, mid = s.next()
        await send_all(clients, tp_display_config(seq, mid))
        await asyncio.sleep(0.3)
        # Init
        seq, mid = s.next()
        await send_all(clients, tp_init(seq, mid, total_lines))
        await asyncio.sleep(0.5)
        # Pages 0-9
        for i in range(min(10, len(pages))):
            seq, mid = s.next()
            await send_all(clients, tp_page(seq, mid, i, pages[i]))
            await asyncio.sleep(0.1)
        # Marker
        seq, mid = s.next()
        await send_all(clients, tp_marker(seq, mid))
        await asyncio.sleep(0.1)
        # Pages 10-11
        for i in range(10, min(12, len(pages))):
            seq, mid = s.next()
            await send_all(clients, tp_page(seq, mid, i, pages[i]))
            await asyncio.sleep(0.1)
        # Sync
        seq, mid = s.next()
        await send_all(clients, tp_sync(seq, mid))
        await asyncio.sleep(0.1)
        # Remaining
        for i in range(12, len(pages)):
            seq, mid = s.next()
            await send_all(clients, tp_page(seq, mid, i, pages[i]))
            await asyncio.sleep(0.1)
        print(f"  Sent {len(pages)} pages")
    await with_glasses(run, both=False, keepalive=args.keepalive)

async def cmd_text(args):
    """NUS text — no auth needed."""
    print("Scanning...")
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)
    targets = {}
    for d, adv in devices.values():
        if d.name and "G2" in d.name:
            side = "L" if "_L_" in d.name else "R" if "_R_" in d.name else "?"
            targets[side] = d
    for side, dev in targets.items():
        c = BleakClient(dev)
        await c.connect()
        payload = bytes([0x4E]) + args.text.encode()
        await c.write_gatt_char(NUS_TX, payload, response=False)
        print(f"  {side}: sent '{args.text}'")
        await asyncio.sleep(3)
        await c.disconnect()
    print("Done.")

async def cmd_voice(args):
    """Record from Mac mic, transcribe with Whisper, display on glasses."""
    import sounddevice as sd
    import numpy as np
    import whisper

    duration = args.duration
    model_name = args.model

    # Record
    print(f"Loading Whisper ({model_name})...")
    model = whisper.load_model(model_name)
    sr = 16000
    print(f"\n>>> Recording {duration}s from Mac mic — speak now <<<")
    audio = sd.rec(int(duration * sr), samplerate=sr, channels=1, dtype="float32")
    sd.wait()
    audio = audio.flatten()
    print(f"  Captured {len(audio)/sr:.1f}s audio")

    # Transcribe
    print("Transcribing...")
    result = whisper.transcribe(model, audio, language=args.lang or None)
    text = result["text"].strip()
    if not text:
        print("  No speech detected.")
        return
    print(f"  \"{text}\"")

    # Send to glasses
    async def run(clients, s):
        seq, mid = s.next()
        await send_all(clients, ai_ctrl_enter(seq, mid))
        await asyncio.sleep(0.3)
        seq, mid = s.next()
        await send_all(clients, ai_ask(seq, mid, text))
        print(f"  Q: {text}")
        if args.reply:
            await asyncio.sleep(0.5)
            seq, mid = s.next()
            await send_all(clients, ai_reply(seq, mid, args.reply))
            print(f"  A: {args.reply}")
    await with_glasses(run, both=False, keepalive=args.keepalive)

async def cmd_dash(args):
    """Just connect, auth, and keep alive — show default dashboard."""
    async def run(clients, s):
        print("  Dashboard active")
    await with_glasses(run, both=True, keepalive=args.keepalive)

def ai_heartbeat(seq, mid):
    """AI session heartbeat (type=9) on 0x07-20 — keeps AI mode alive."""
    return packet(seq, 0x07, 0x20, vi(1, 9) + vi(2, mid))


async def cmd_tap(args):
    """Interactive press counter — press touchpad to increment, Ctrl-C to quit."""
    count = 0
    taps = []

    def _f10_val(payload):
        """Extract f10.f1 value from AI EVENT protobuf."""
        for i in range(len(payload) - 3):
            if payload[i] == 0x52 and i + 3 < len(payload) and payload[i+2] == 0x08:
                return payload[i+3]
        return None

    def on_rx(sender, data):
        raw = bytes(data)
        if len(raw) < 8 or raw[0] != 0xAA:
            return
        svc_hi, svc_lo = raw[6], raw[7]
        payload = raw[8:-2] if len(raw) > 10 else b''
        # type=8 (EVENT) on 0x07-01 = touch event
        if svc_hi == 0x07 and svc_lo == 0x01 and len(payload) > 2:
            if payload[0] == 0x08 and payload[1] == 0x08:
                # f10.f1=2 = touch-down (new press), f10.f1=1 = held (ignore)
                if _f10_val(payload) == 0x02:
                    taps.append(time.time())

    print("=== Interactive Tap Counter ===\n")
    print("Scanning...")
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)
    right = None
    for d, adv in devices.values():
        if d.name and "G2" in d.name and "_R_" in d.name:
            right = d
            print(f"  R: {d.name} (RSSI {adv.rssi})")
    if not right:
        print("No G2 right eye found!")
        return

    c = BleakClient(right)
    await c.connect()
    await c.start_notify(EUS_RX, on_rx)
    try:
        await c.start_notify(NUS_RX, on_rx)
    except:
        pass

    for pkt in auth_packets():
        await c.write_gatt_char(EUS_TX, pkt, response=False)
        await asyncio.sleep(0.1)
    await asyncio.sleep(0.5)
    print("  Authenticated")

    seq, mid = 0x08, 0x14
    def next_id():
        nonlocal seq, mid
        s, m = seq, mid
        seq += 1; mid += 1
        return s, m

    # Enter AI mode + show prompt
    s, m = next_id()
    await c.write_gatt_char(EUS_TX, ai_ctrl_enter(s, m), response=False)
    await asyncio.sleep(0.3)
    s, m = next_id()
    await c.write_gatt_char(EUS_TX,
        ai_ask(s, m, "Press+hold to count"), response=False)
    await asyncio.sleep(0.5)
    s, m = next_id()
    await c.write_gatt_char(EUS_TX,
        ai_reply(s, m, "Count: 0 "), response=False)

    # Drain any startup phantom event
    await asyncio.sleep(1.0)
    taps.clear()

    print("  Tap the touchpad! (Ctrl-C to quit)")

    try:
        last_hb = time.time()
        while True:
            await asyncio.sleep(0.1)
            # Dual heartbeat every 1s
            if time.time() - last_hb >= 1.0:
                s, m = next_id()
                await c.write_gatt_char(EUS_TX, ai_heartbeat(s, m), response=False)
                s, m = next_id()
                await c.write_gatt_char(EUS_TX, heartbeat(s, m), response=False)
                last_hb = time.time()
            # Process new taps
            while len(taps) > count:
                count += 1
                s, m = next_id()
                await c.write_gatt_char(EUS_TX,
                    ai_reply(s, m, f"| {count} "), response=False)
                print(f"  Count: {count}")
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass

    s, m = next_id()
    await c.write_gatt_char(EUS_TX, ai_ctrl_exit(s, m), response=False)
    await asyncio.sleep(0.3)
    await c.disconnect()
    print(f"\nFinal count: {count}")


async def cmd_ring(args):
    """Use G2 glasses as relay to receive R1 ring events via 0x91 service."""
    ring_events = []
    all_packets = []

    def on_rx(sender, data):
        raw = bytes(data)
        if len(raw) < 8 or raw[0] != 0xAA:
            return
        svc_hi, svc_lo = raw[6], raw[7]
        payload = raw[8:-2] if len(raw) > 10 else b''
        svc = f"0x{svc_hi:02x}-{svc_lo:02x}"
        all_packets.append((svc, payload))
        if svc_hi == 0x91:
            ring_events.append((svc, payload))
            print(f"  RING {svc}: {hexstr(payload)}")
        elif args.verbose:
            print(f"  [{svc}] {hexstr(payload[:30])}")

    print("=== G2 Ring Relay ===\n")
    print("Scanning for G2...")
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)
    targets = {}
    for d, adv in devices.values():
        if d.name and "G2" in d.name:
            side = "L" if "_L_" in d.name else "R" if "_R_" in d.name else "?"
            targets[side] = d
            print(f"  {side}: {d.name} (RSSI {adv.rssi})")

    if not targets:
        print("No G2 found!")
        return

    # Connect to right eye (ring connects to right)
    key = "R" if "R" in targets else list(targets.keys())[0]
    dev = targets[key]
    c = BleakClient(dev)
    await c.connect()
    await c.start_notify(EUS_RX, on_rx)
    try:
        await c.start_notify(NUS_RX, on_rx)
    except:
        pass

    # Auth
    for pkt in auth_packets():
        await c.write_gatt_char(EUS_TX, pkt, response=False)
        await asyncio.sleep(0.1)
    await asyncio.sleep(0.5)
    print(f"  {key} authenticated")

    seq, mid = 0x08, 0x14

    # Ring relay protocol (0x91-20):
    # f1=type(varint), f2=msg_id(varint), f3=payload_len(varint),
    # f4=payload_data(bytes,max6), f5=ring_command(varint), f6=ring_data(varint), f7=0(varint)
    def ring_relay(s, m, payload_data=b'', ring_cmd=0, ring_data=0):
        p = vi(1, 1) + vi(2, m)  # type=1 (ring relay), msg_id
        if payload_data:
            p += vi(3, len(payload_data))  # payload_len
            p += ld(4, payload_data)       # payload_data
        if ring_cmd:
            p += vi(5, ring_cmd)           # ring_command
        if ring_data:
            p += vi(6, ring_data)          # ring_data
        p += vi(7, 0)                      # terminator
        return packet(s, 0x91, 0x20, p)

    # Ring MAC from advertising (EVEN R1_ECC0CF → CF:C0:EC:4C:52:C1)
    ring_mac = bytes([0xCF, 0xC0, 0xEC, 0x4C, 0x52, 0xC1])

    print("\n--- Phase 1: Query ring status ---")
    for cmd_id in [1, 2, 3, 4]:
        p = vi(1, cmd_id) + vi(2, mid)
        await c.write_gatt_char(EUS_TX, packet(seq, 0x91, 0x20, p), response=False)
        print(f"  cmd={cmd_id}")
        seq += 1; mid += 1
        await asyncio.sleep(0.4)

    print(f"\n--- Phase 2: Try binding ring to G2 ---")
    # Send ring MAC via relay — try as RingEvent.ringMac (f3.f1)
    # RingDataPackage: f1=1(EVENT), f2=mid, f3=RingEvent{f1=mac, f2=1(BLE_ADV)}
    ring_event = ld(1, ring_mac) + vi(2, 1)  # ringMac + eventId=BLE_ADV
    p = vi(1, 1) + vi(2, mid) + ld(3, ring_event)
    await c.write_gatt_char(EUS_TX, packet(seq, 0x91, 0x20, p), response=False)
    print(f"  EVENT with ring MAC")
    seq += 1; mid += 1
    await asyncio.sleep(0.5)

    # Try MAC as raw payload_data (f4)
    p = vi(1, 1) + vi(2, mid) + vi(3, 6) + ld(4, ring_mac) + vi(7, 0)
    await c.write_gatt_char(EUS_TX, packet(seq, 0x91, 0x20, p), response=False)
    print(f"  Relay with MAC in f4")
    seq += 1; mid += 1
    await asyncio.sleep(0.5)

    # Try openRingBroadcast — cmd=3 with enable payload
    for enable_val in [1, 0x01, 0x02]:
        inner = vi(1, enable_val)
        p = vi(1, 3) + vi(2, mid) + ld(3, inner)
        await c.write_gatt_char(EUS_TX, packet(seq, 0x91, 0x20, p), response=False)
        print(f"  cmd=3 f3.f1={enable_val}")
        seq += 1; mid += 1
        await asyncio.sleep(0.4)

    # Try cmd=4 controlDevice variations
    for val in [1, 2, 3]:
        p = vi(1, 4) + vi(2, mid) + ld(3, vi(1, val))
        await c.write_gatt_char(EUS_TX, packet(seq, 0x91, 0x20, p), response=False)
        print(f"  cmd=4 f3.f1={val}")
        seq += 1; mid += 1
        await asyncio.sleep(0.4)

    # Try sending ring MAC + connect request as cmd=1 with full event
    # RingEvent: f1=ringMac, f2=eventId(1=BLE_ADV), f3=eventParam(1)
    ring_evt2 = ld(1, ring_mac) + vi(2, 1) + vi(3, 1)
    p = vi(1, 1) + vi(2, mid) + ld(3, ring_evt2)
    await c.write_gatt_char(EUS_TX, packet(seq, 0x91, 0x20, p), response=False)
    print(f"  EVENT MAC+BLE_ADV+param=1")
    seq += 1; mid += 1
    await asyncio.sleep(0.5)

    print(f"\n  {len(ring_events)} ring responses so far")

    # Listen
    duration = args.duration
    print(f"\n>>> Listening {duration}s (tap ring!) <<<\n")
    for i in range(duration):
        await asyncio.sleep(1)
        if i % 3 == 0:
            p = vi(1, 0x0E) + vi(2, mid) + ld(13, b'')
            await c.write_gatt_char(EUS_TX, packet(seq, 0x80, 0x00, p), response=False)
            seq += 1; mid += 1
        if i % 15 == 0:
            print(f"  [{i}s] {len(ring_events)} ring, {len(all_packets)} total")

    print(f"\n=== {len(ring_events)} ring relay events ===")
    for svc, p in ring_events:
        print(f"  {svc}: {hexstr(p)}")
    if not ring_events:
        print(f"\nAll {len(all_packets)} packets (last 20):")
        for svc, p in all_packets[-20:]:
            print(f"  {svc}: {hexstr(p[:40])}")

    await c.disconnect()
    print("Done.")

# ── Unicode art patterns ──

PATTERNS = {
    "bars": lambda: "\n".join(
        f"{'█' * (i+1)}{'▒' * (10-i)} {(i+1)*10}%"
        for i in range(10)
    ),
    "gradient": lambda: "\n".join([
        "▏▎▍▌▋▊▉█ brightness",
        "▁▂▃▄▅▆▇█ height",
        "",
        "█████████████████",
        "▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇",
        "▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆",
        "▅▅▅▅▅▅▅▅▅▅▅▅▅▅▅▅▅",
        "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄",
        "▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃",
        "▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂",
        "▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁",
    ]),
    "shapes": lambda: "\n".join([
        "● ○ ■ □ ▲ △ ▼ ▽",
        "◆ ◇ ★ ☆ ◀ ▶ ◁ ▷",
        "◎ ◐ ◑ ◢ ◣ ◤ ◥ ◯",
        "",
        "← ↑ → ↓ ↔ ↕",
        "↖ ↗ ↘ ↙ ⇒ ⇔",
    ]),
    "status": lambda: "\n".join([
        "━━━ System Status ━━━",
        "",
        "★ CPU  ██████████▒▒ 83%",
        "★ MEM  ████████▒▒▒▒ 67%",
        "★ DISK ████▒▒▒▒▒▒▒▒ 33%",
        "★ NET  ███████████▒ 92%",
        "",
        "▲ 4 alerts  ● 2 active",
    ]),
    "poem": lambda: "\n".join([
        "Through silicon veins",
        "and copper nerves I speak",
        "━━━",
        "a lens upon your world",
        "no screen between us",
        "━━━",
        "Light bends to words",
        "words bend to thought",
        "and thought escapes",
        "the pocket where it hid",
        "━━━",
        "We are the ones",
        "who pried the lid.",
    ]),
    "dashboard": lambda: "\n".join([
        "━━━ G2 ← Mac Direct ━━━",
        "",
        f"☆ {time.strftime('%H:%M:%S')}",
        f"☆ {time.strftime('%Y-%m-%d')}",
        "",
        "★ BLE: Connected",
        "★ Auth: OK",
        "★ Display: EvenAI",
        "",
        "◆ No phone needed ◆",
    ]),
}

async def cmd_draw(args):
    pattern = args.pattern
    if pattern == "list":
        print("Available patterns:", ", ".join(PATTERNS.keys()))
        return
    if pattern not in PATTERNS:
        print(f"Unknown pattern '{pattern}'. Available: {', '.join(PATTERNS.keys())}")
        return
    text = PATTERNS[pattern]()
    async def run(clients, s):
        seq, mid = s.next()
        await send_all(clients, ai_ctrl_enter(seq, mid))
        await asyncio.sleep(0.3)
        # Stream line by line
        for line in text.split("\n"):
            seq, mid = s.next()
            for c in clients.values():
                await c.write_gatt_char(EUS_TX, ai_reply(seq, mid, line + "\n"), response=False)
            await asyncio.sleep(0.12)
        print(f"  Sent {pattern}:\n{text}")
    await with_glasses(run, both=False, keepalive=args.keepalive)

# ── CLI ──

def main():
    p = argparse.ArgumentParser(description="Even G2 glasses driver")
    p.add_argument("--keepalive", "-k", type=int, default=15, help="Keepalive duration (x2 sec)")
    sub = p.add_subparsers(dest="cmd", required=True)

    ai = sub.add_parser("ai", help="Even AI Q&A display")
    ai.add_argument("question")
    ai.add_argument("answer")

    nav = sub.add_parser("nav", help="Navigation display")
    nav.add_argument("instruction", help="e.g. 'Turn left'")
    nav.add_argument("distance", help="e.g. '100 m'")
    nav.add_argument("--time", help="Time remaining")
    nav.add_argument("--total", help="Total distance")
    nav.add_argument("--eta", help="ETA string")
    nav.add_argument("--speed", help="Speed string")
    nav.add_argument("--icon", default="straight", choices=["left","right","straight","uturn"])

    tp = sub.add_parser("teleprompter", help="Teleprompter text display")
    tp.add_argument("text")

    cv = sub.add_parser("conversate", help="Live transcription display")
    cv.add_argument("texts", nargs="+", help="Transcript segments")

    tx = sub.add_parser("text", help="NUS text (no auth)")
    tx.add_argument("text")

    vo = sub.add_parser("voice", help="Mac mic → Whisper → glasses AI display")
    vo.add_argument("--duration", "-d", type=int, default=5, help="Recording seconds (default 5)")
    vo.add_argument("--model", "-m", default="base", help="Whisper model (tiny/base/small/medium)")
    vo.add_argument("--lang", "-l", default=None, help="Language code (en/zh/etc, auto if omitted)")
    vo.add_argument("--reply", "-r", default=None, help="Optional reply text to display")

    dr = sub.add_parser("draw", help="Unicode art patterns on AI display")
    dr.add_argument("pattern", help="Pattern name (or 'list' to show all)")

    sub.add_parser("dash", help="Dashboard keepalive")

    sub.add_parser("tap", help="Interactive tap counter on glasses touchpad")

    rg = sub.add_parser("ring", help="Ring relay via G2 glasses (0x91)")
    rg.add_argument("--duration", "-d", type=int, default=60, help="Listen duration (seconds)")
    rg.add_argument("--verbose", "-v", action="store_true", help="Show all packets")

    args = p.parse_args()
    handlers = {"ai": cmd_ai, "nav": cmd_nav, "teleprompter": cmd_teleprompter,
                "conversate": cmd_conversate, "text": cmd_text, "voice": cmd_voice,
                "draw": cmd_draw, "tap": cmd_tap, "ring": cmd_ring,
                "dash": cmd_dash}
    asyncio.run(handlers[args.cmd](args))

if __name__ == "__main__":
    main()
