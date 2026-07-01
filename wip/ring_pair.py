#!/usr/bin/env python3
"""R1 Ring — force BLE pairing via direct CoreBluetooth + IOBluetooth."""
import asyncio, time, subprocess
from bleak import BleakClient, BleakScanner

RING_SVC  = "bae80001-4f05-4503-8e65-3af1f7329d1f"
RING_EVT  = "bae80011-4f05-4503-8e65-3af1f7329d1f"
RING_RX   = "bae80013-4f05-4503-8e65-3af1f7329d1f"
RING_NAMES = ("Even Ring", "R1", "EVEN_RING", "EvenRing")

def hexstr(d): return " ".join(f"{b:02x}" for b in d)


async def find_ring():
    devices = await BleakScanner.discover(timeout=15.0, return_adv=True)
    for d, adv in devices.values():
        name = d.name or ""
        if any(n in name for n in RING_NAMES) or RING_SVC in [str(s) for s in (adv.service_uuids or [])]:
            print(f"  Found: {name} (RSSI {adv.rssi})")
            print(f"  CB UUID: {d.address}")
            mfr = adv.manufacturer_data
            if mfr:
                for k, v in mfr.items():
                    mac_bytes = bytes(v)
                    print(f"  MAC: {':'.join(f'{b:02X}' for b in mac_bytes)}")
            return d
    return None


async def try_iobt_pair(ring):
    """Try pairing via IOBluetooth framework (Objective-C bridge)."""
    try:
        import objc
        IOBluetooth = objc.loadBundle(
            'IOBluetooth',
            bundle_path='/System/Library/Frameworks/IOBluetooth.framework',
            module_globals=globals()
        )
        # IOBluetoothDevice can pair classic BT devices
        # For BLE, we need to go through CoreBluetooth
        print("  IOBluetooth loaded")

        # Try to find the device via IOBluetoothDevice
        # This only works for classic BT, not BLE
        # But let's try anyway
        mfr_mac = "CF:C0:EC:4C:52:C1"
        device = IOBluetoothDevice.deviceWithAddressString_(mfr_mac)
        if device:
            print(f"  Found IOBluetooth device: {device}")
            result = device.openConnection()
            print(f"  openConnection: {result}")
            result = device.requestAuthentication()
            print(f"  requestAuthentication: {result}")
        else:
            print(f"  IOBluetoothDevice not found for {mfr_mac}")
    except Exception as e:
        print(f"  IOBluetooth error: {e}")


async def try_cb_pair(ring):
    """Try pairing via CoreBluetooth by accessing encrypted service."""
    import objc
    from Foundation import NSRunLoop, NSDate, NSUUID
    import CoreBluetooth

    paired = asyncio.Event()
    extra_services = []

    class CentralDelegate(CoreBluetooth.NSObject):
        def init(self):
            self = objc.super(CentralDelegate, self).init()
            self.peripheral = None
            self.connected = False
            return self

        def centralManagerDidUpdateState_(self, central):
            if central.state() == 5:  # PoweredOn
                print("  CB: Powered on, scanning...")
                central.scanForPeripheralsWithServices_options_(None, None)

        def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, peripheral, adv, rssi):
            name = peripheral.name() or ""
            if any(n in name for n in RING_NAMES):
                print(f"  CB: Found {name}, connecting...")
                central.stopScan()
                self.peripheral = peripheral
                central.connectPeripheral_options_(peripheral, None)

        def centralManager_didConnectPeripheral_(self, central, peripheral):
            print(f"  CB: Connected! Discovering services...")
            self.connected = True
            peripheral.setDelegate_(self)
            # Discover ALL services
            peripheral.discoverServices_(None)

        def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
            print(f"  CB: Connect failed: {error}")

        def peripheral_didDiscoverServices_(self, peripheral, error):
            if error:
                print(f"  CB: Service discovery error: {error}")
                return
            for svc in peripheral.services():
                uuid_str = str(svc.UUID())
                print(f"  CB: Service: {uuid_str}")
                extra_services.append(uuid_str)
                peripheral.discoverCharacteristics_forService_(None, svc)

        def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
            if error:
                print(f"  CB: Char discovery error: {error}")
                return
            for char in service.characteristics():
                props = char.properties()
                prop_str = []
                if props & 0x01: prop_str.append("broadcast")
                if props & 0x02: prop_str.append("read")
                if props & 0x04: prop_str.append("write-no-resp")
                if props & 0x08: prop_str.append("write")
                if props & 0x10: prop_str.append("notify")
                if props & 0x20: prop_str.append("indicate")
                if props & 0x40: prop_str.append("auth-write")
                if props & 0x80: prop_str.append("ext-props")
                print(f"    {char.UUID()} [{', '.join(prop_str)}]")

                # Try to read ANY readable characteristic — might trigger pairing
                if props & 0x02:  # readable
                    print(f"    Attempting read (may trigger pairing)...")
                    peripheral.readValueForCharacteristic_(char)

                # Try to subscribe to notify/indicate
                if props & 0x10 or props & 0x20:
                    peripheral.setNotifyValue_forCharacteristic_(True, char)

        def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, characteristic, error):
            if error:
                print(f"  CB: Read error on {characteristic.UUID()}: {error}")
            else:
                val = characteristic.value()
                if val:
                    data = bytes(val)
                    print(f"  CB: Value {characteristic.UUID()}: {hexstr(data)}")

        def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, peripheral, characteristic, error):
            if error:
                print(f"  CB: Notify error on {characteristic.UUID()}: {error}")
            else:
                print(f"  CB: Notify enabled for {characteristic.UUID()}")

    delegate = CentralDelegate.alloc().init()
    central = CoreBluetooth.CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)

    # Run the CoreBluetooth event loop for 15 seconds
    print("  CB: Starting...")
    deadline = time.time() + 20
    while time.time() < deadline:
        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(0.1)
        )
        await asyncio.sleep(0.01)

    print(f"  CB: Found {len(extra_services)} services")
    return extra_services


async def main():
    print("=== R1 Ring — Force Pair ===\n")

    print("Step 1: Find ring via Bleak...")
    ring = await find_ring()
    if not ring:
        print("No ring found!")
        return

    print("\nStep 2: Try IOBluetooth pairing...")
    await try_iobt_pair(ring)

    print("\nStep 3: Try CoreBluetooth direct access...")
    services = await try_cb_pair(ring)

    print("\nStep 4: Check paired list...")
    result = subprocess.run(["blueutil", "--paired"], capture_output=True, text=True)
    for line in result.stdout.split("\n"):
        if "R1" in line or "ring" in line.lower() or "ECC0" in line:
            print(f"  FOUND: {line}")
            break
    else:
        print("  Ring still not paired")

    # Now reconnect via Bleak and check if more services are visible
    print("\nStep 5: Reconnect via Bleak, check services...")
    c = BleakClient(ring)
    await c.connect()
    print(f"Connected (MTU={c.mtu_size})")
    for svc in c.services:
        print(f"  {svc.uuid}")
        for char in svc.characteristics:
            props = ", ".join(char.properties)
            print(f"    {char.uuid} [{props}] h=0x{char.handle:04X}")

    events = []
    def on_any(sender, data):
        raw = bytes(data)
        handle = getattr(sender, 'handle', None) or sender
        events.append((handle, raw))
        if len(raw) >= 3 and raw[0] == 0xFF:
            print(f"  *** GESTURE: {hexstr(raw)} ***")
        else:
            print(f"  [0x{handle:04X}] ({len(raw)}B): {hexstr(raw)}")

    for svc in c.services:
        for char in svc.characteristics:
            if "notify" in char.properties or "indicate" in char.properties:
                try:
                    await c.start_notify(char.uuid, on_any)
                except:
                    pass

    print(f"\n>>> Listening 30s — tap/swipe ring! <<<\n")
    for i in range(30):
        await asyncio.sleep(1)
        if i % 10 == 0:
            print(f"  [{i}s] {len(events)} events")

    await c.disconnect()
    print(f"\n{len(events)} events total")
    print("Done.")


if __name__ == "__main__":
    asyncio.run(main())
