#!/usr/bin/env python3
"""Complete G2 onboarding by sending end-state to both eyes."""
import asyncio
import time
from bleak import BleakClient, BleakScanner

UUID_BASE = "00002760-08c2-11e1-9073-0e8ac72e{:04x}"
EUS_TX = UUID_BASE.format(0x5401)
EUS_RX = UUID_BASE.format(0x5402)

def hexstr(d): return " ".join(f"{b:02x}" for b in d)

def crc16_ccitt(data, init=0xFFFF):
    crc = init
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc

def encode_varint(value):
    result = []
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)

def build_packet(seq, svc_hi, svc_lo, payload):
    header = bytes([0xAA, 0x21, seq, len(payload) + 2, 0x01, 0x01, svc_hi, svc_lo])
    pkt = header + payload
    crc = crc16_ccitt(payload)
    return pkt + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

def build_auth_packets():
    ts = int(time.time())
    ts_v = encode_varint(ts)
    txid = bytes([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    pkts = []
    pkts.append(build_packet(0x01, 0x80, 0x00,
        bytes([0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])))
    pkts.append(build_packet(0x02, 0x80, 0x20,
        bytes([0x08, 0x05, 0x10, 0x0E, 0x22, 0x02, 0x08, 0x02])))
    p3 = bytes([0x08, 0x80, 0x01, 0x10, 0x0F, 0x82, 0x08]) + \
         encode_varint(len(bytes([0x08]) + ts_v + bytes([0x10]) + txid)) + \
         bytes([0x08]) + ts_v + bytes([0x10]) + txid
    pkts.append(build_packet(0x03, 0x80, 0x20, p3))
    pkts.append(build_packet(0x04, 0x80, 0x00,
        bytes([0x08, 0x04, 0x10, 0x10, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])))
    pkts.append(build_packet(0x05, 0x80, 0x00,
        bytes([0x08, 0x04, 0x10, 0x11, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])))
    pkts.append(build_packet(0x06, 0x80, 0x20,
        bytes([0x08, 0x05, 0x10, 0x12, 0x22, 0x02, 0x08, 0x01])))
    p7 = bytes([0x08, 0x80, 0x01, 0x10, 0x13, 0x82, 0x08]) + \
         encode_varint(len(bytes([0x08]) + ts_v + bytes([0x10]) + txid)) + \
         bytes([0x08]) + ts_v + bytes([0x10]) + txid
    pkts.append(build_packet(0x07, 0x80, 0x20, p7))
    return pkts


async def setup_eye(dev, label):
    """Connect, auth, and send onboarding completion to one eye."""
    responses = []
    def on_rx(sender, data):
        if len(data) >= 8 and data[0] == 0xAA:
            svc = f"0x{data[6]:02x}-{data[7]:02x}"
            payload = data[8:-2] if len(data) > 10 else b''
            responses.append((svc, payload))
            print(f"  [{label}] {svc}: {hexstr(payload)}")
        elif data[0] != 0xF5:
            print(f"  [{label}] raw: {hexstr(data[:20])}")

    c = BleakClient(dev)
    await c.connect()
    await c.start_notify(EUS_RX, on_rx)
    print(f"  [{label}] Connected")

    # Auth
    for pkt in build_auth_packets():
        await c.write_gatt_char(EUS_TX, pkt, response=False)
        await asyncio.sleep(0.1)
    await asyncio.sleep(1.0)
    print(f"  [{label}] Auth done ({len(responses)} responses)")
    responses.clear()

    seq = 0x08
    mid = 0x14

    # Walk through ALL onboarding states 0-7 (must not skip!)
    for state in range(8):
        print(f"  [{label}] State {state}...")
        payload = bytes([0x08, 0x01, 0x10]) + encode_varint(mid) + bytes([0x1A])
        if state == 0:
            payload += bytes([0x00])  # empty f3
        else:
            payload += bytes([0x02, 0x08]) + encode_varint(state)
        pkt = build_packet(seq, 0x10, 0x20, payload)
        await c.write_gatt_char(EUS_TX, pkt, response=False)
        seq += 1; mid += 1
        await asyncio.sleep(0.8)

    # Event cmd=3 with f3={f1=1} to signal completion
    print(f"  [{label}] Event cmd=3...")
    payload = bytes([0x08, 0x03, 0x10]) + encode_varint(mid) + bytes([0x1A, 0x02, 0x08, 0x01])
    pkt = build_packet(seq, 0x10, 0x20, payload)
    await c.write_gatt_char(EUS_TX, pkt, response=False)
    seq += 1; mid += 1
    await asyncio.sleep(0.5)

    # Send time sync on 0x0A-20 (phone time)
    ts = int(time.time())
    ts_v = encode_varint(ts)
    tz_offset = -7 * 4  # UTC-7 in 15-min units, adjust as needed
    tz_v = encode_varint(abs(tz_offset)) if tz_offset >= 0 else encode_varint(((-tz_offset) ^ 0xFFFFFFFF) + 1)
    # f128 = {f1=timestamp, f3=tz_offset} => field 16, wire 2
    inner = bytes([0x08]) + ts_v + bytes([0x18]) + encode_varint(abs(tz_offset) * 2)  # zigzag for signed
    time_payload = bytes([0x82, 0x08]) + encode_varint(len(inner)) + inner
    print(f"  [{label}] Sending time sync...")
    pkt = build_packet(seq, 0x0A, 0x20, time_payload)
    await c.write_gatt_char(EUS_TX, pkt, response=False)
    seq += 1; mid += 1
    await asyncio.sleep(0.5)

    # Keepalive
    print(f"  [{label}] Monitoring (20s)...")
    for i in range(10):
        await asyncio.sleep(2)
        hb = build_packet(seq, 0x80, 0x00,
            bytes([0x08, 0x0E, 0x10]) + encode_varint(mid))
        seq += 1; mid += 1
        await c.write_gatt_char(EUS_TX, hb, response=False)

    await c.disconnect()
    print(f"  [{label}] Done")


async def main():
    print("=== G2 Onboarding Completion ===\n")
    print("Scanning...")
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)

    targets = {}
    for d, adv in devices.values():
        if d.name and "G2" in d.name:
            side = "L" if "_L_" in d.name else "R" if "_R_" in d.name else "?"
            targets[side] = d
            print(f"  Found {side}: {d.name} (RSSI {adv.rssi})")

    if not targets:
        print("No G2 glasses found!")
        return

    # Run both eyes in parallel
    tasks = []
    for side, dev in sorted(targets.items()):
        tasks.append(setup_eye(dev, side))

    await asyncio.gather(*tasks)
    print("\nAll done.")


if __name__ == "__main__":
    asyncio.run(main())
