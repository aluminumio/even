#!/usr/bin/env python3
"""Parse BTSnoop log to find G2 onboarding packets (0x10-20 and 0x0D-20)."""
import struct, sys

def parse_btsnoop(filepath):
    with open(filepath, 'rb') as f:
        # Header: "btsnoop\0" + version(4) + datalink_type(4) = 16 bytes
        hdr = f.read(16)
        if hdr[:8] != b'btsnoop\x00':
            print("Not a btsnoop file!")
            return

        records = []
        while True:
            # Record header: orig_len(4) + incl_len(4) + flags(4) + drops(4) + ts(8) = 24 bytes
            rec_hdr = f.read(24)
            if len(rec_hdr) < 24:
                break
            orig_len, incl_len, flags, drops, ts = struct.unpack('>IIIII', rec_hdr[:20])
            ts_bytes = struct.unpack('>Q', rec_hdr[16:24])[0]
            data = f.read(incl_len)
            if len(data) < incl_len:
                break
            records.append((flags, ts_bytes, data))

    print(f"Total records: {len(records)}")

    # Look for G2 packets (0xAA header) in HCI ACL data
    g2_packets = []
    for i, (flags, ts, data) in enumerate(records):
        # HCI packet type is first byte
        if len(data) < 5:
            continue
        hci_type = data[0]

        # ACL data = 0x02
        if hci_type == 0x02 and len(data) > 9:
            # HCI ACL: handle(2) + length(2) + L2CAP length(2) + channel(2) + ATT data
            acl_data = data[5:]  # Skip HCI header (1+2+2)
            if len(acl_data) < 4:
                continue
            l2cap_len = struct.unpack('<H', acl_data[:2])[0]
            l2cap_cid = struct.unpack('<H', acl_data[2:4])[0]
            att_data = acl_data[4:]

            # Look for ATT Write Command (0x52) or ATT Handle Value Notification (0x1B)
            if len(att_data) >= 3:
                att_opcode = att_data[0]
                att_handle = struct.unpack('<H', att_data[1:3])[0]
                att_value = att_data[3:]

                if len(att_value) >= 8 and att_value[0] == 0xAA:
                    # G2 packet!
                    direction = "TX" if att_value[1] == 0x21 else "RX" if att_value[1] == 0x12 else "??"
                    seq = att_value[2]
                    plen = att_value[3]
                    svc_hi = att_value[6]
                    svc_lo = att_value[7]
                    svc = f"0x{svc_hi:02x}-{svc_lo:02x}"
                    payload = att_value[8:-2] if len(att_value) > 10 else b''

                    # Filter for onboarding (0x10) and settings (0x0D)
                    if svc_hi in (0x10, 0x0D, 0x0A, 0x04, 0x80):
                        g2_packets.append((i, direction, svc, seq, payload, att_value))

    print(f"\nRelevant G2 packets (services 0x10, 0x0D, 0x0A, 0x04, 0x80):")
    print(f"Found {len(g2_packets)} packets\n")

    for idx, (rec_i, direction, svc, seq, payload, raw) in enumerate(g2_packets):
        ph = " ".join(f"{b:02x}" for b in payload[:32])
        att = "Write" if flags == 0 else "Notif"
        print(f"  [{idx:3d}] rec={rec_i:5d} {direction} {svc} seq={seq:3d} payload({len(payload):2d}b): {ph}")
        # Special decode for onboarding
        if svc.startswith("0x10"):
            # Decode protobuf fields
            decode_protobuf(payload, "    ")
        if svc == "0x0d-20" or svc == "0x0d-00":
            decode_protobuf(payload, "    ")

def decode_protobuf(data, prefix=""):
    """Simple protobuf field decoder."""
    i = 0
    while i < len(data):
        if i >= len(data):
            break
        tag_byte = data[i]
        field_num = tag_byte >> 3
        wire_type = tag_byte & 0x07
        i += 1

        if wire_type == 0:  # Varint
            val = 0
            shift = 0
            while i < len(data):
                b = data[i]
                i += 1
                val |= (b & 0x7F) << shift
                shift += 7
                if not (b & 0x80):
                    break
            print(f"{prefix}f{field_num} = {val} (varint)")
        elif wire_type == 2:  # Length-delimited
            if i >= len(data):
                break
            length = data[i]
            i += 1
            blob = data[i:i+length]
            i += length
            ph = " ".join(f"{b:02x}" for b in blob[:16])
            print(f"{prefix}f{field_num} = [{length}b] {ph}")
            if length > 0 and length < 20:
                decode_protobuf(blob, prefix + "  ")
        elif wire_type == 5:  # 32-bit
            if i + 4 <= len(data):
                val = struct.unpack('<I', data[i:i+4])[0]
                i += 4
                print(f"{prefix}f{field_num} = 0x{val:08x} (fixed32)")
            else:
                break
        else:
            print(f"{prefix}f{field_num} wire={wire_type} (unknown)")
            break


if __name__ == "__main__":
    f = sys.argv[1] if len(sys.argv) > 1 else "/Users/jonathan/Projects/even/even-g2-protocol/captures/fresh-pairing.log"
    parse_btsnoop(f)
