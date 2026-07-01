#!/usr/bin/env python3
"""Even R1 Ring — BLE connection attempt.

NOTE: Gesture events require BLE bonding which macOS CoreBluetooth
cannot initiate (no encrypted characteristics visible to trigger it).
Use G2 glasses touchpad via `g2.py tap` instead.
"""
import asyncio, time
from bleak import BleakClient, BleakScanner

RING_SVC  = "bae80001-4f05-4503-8e65-3af1f7329d1f"
RING_CMD  = "bae80010-4f05-4503-8e65-3af1f7329d1f"
RING_EVT  = "bae80011-4f05-4503-8e65-3af1f7329d1f"
RING_TX   = "bae80012-4f05-4503-8e65-3af1f7329d1f"
RING_RX   = "bae80013-4f05-4503-8e65-3af1f7329d1f"
RING_NAMES = ("Even Ring", "R1", "EVEN_RING", "EvenRing")

def hexstr(d): return " ".join(f"{b:02x}" for b in d)


async def main():
    print("=== R1 Ring — Scan + Dump ===\n")
    print("Scanning...")
    devices = await BleakScanner.discover(timeout=15.0, return_adv=True)
    ring = None
    for d, adv in devices.values():
        name = d.name or ""
        if any(n in name for n in RING_NAMES) or RING_SVC in [str(s) for s in (adv.service_uuids or [])]:
            ring = d
            print(f"  Found: {name} (RSSI {adv.rssi})")
            mfr = adv.manufacturer_data
            if mfr:
                for k, v in mfr.items():
                    print(f"  Mfr 0x{k:04X}: {hexstr(bytes(v))}")

    if not ring:
        print("No ring found!")
        return

    c = BleakClient(ring)
    await c.connect()
    print("Services:")
    for svc in c.services:
        print(f"  {svc.uuid}")
        for char in svc.characteristics:
            props = ", ".join(char.properties)
            print(f"    {char.uuid} [{props}] h=0x{char.handle:04X}")

    events = []
    t0 = time.time()
    def on_any(sender, data):
        raw = bytes(data)
        handle = getattr(sender, 'handle', None) or sender
        elapsed = time.time() - t0
        events.append((handle, elapsed, raw))
        print(f"  [{elapsed:5.1f}s] h=0x{handle:04X} ({len(raw)}B): {hexstr(raw)}")

    await c.start_notify(RING_EVT, on_any)
    await c.start_notify(RING_RX, on_any)

    print(f"\nListening 30s...")
    for i in range(30):
        await asyncio.sleep(1)
        if i % 10 == 0:
            print(f"  [{i}s] {len(events)} events")

    await c.disconnect()
    print(f"\n{len(events)} events. Done.")


if __name__ == "__main__":
    asyncio.run(main())
