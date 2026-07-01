#!/usr/bin/env python3
"""Scan for Even G2 glasses over BLE."""
import asyncio
from bleak import BleakScanner


async def main():
    print("Scanning for BLE devices (10 seconds)...")
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)

    g2 = []
    all_devs = []
    for d, adv in devices.values():
        all_devs.append((d, adv))
        if d.name and ("G2" in d.name or "even" in d.name.lower()):
            g2.append((d, adv))

    if g2:
        print(f"\nFound {len(g2)} Even device(s):")
        for d, adv in g2:
            print(f"  {d.name:40s}  {d.address}  RSSI={adv.rssi}")
    else:
        print("\nNo Even G2 devices found.")
        print("Make sure glasses are:")
        print("  1. Powered on (out of case)")
        print("  2. NOT connected to your phone")
        print("  3. In range")
        print(f"\nAll {len(all_devs)} devices found:")
        for d, adv in sorted(all_devs, key=lambda x: x[1].rssi or -999, reverse=True)[:20]:
            name = d.name or "(unnamed)"
            print(f"  {name:40s}  {d.address}  RSSI={adv.rssi}")


if __name__ == "__main__":
    asyncio.run(main())
