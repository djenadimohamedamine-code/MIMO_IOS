import struct

def build_video_header(codec, width, height, frn, frd, ar, flags, cs, payload_len):
    # Main header (16 bytes)
    version = 1
    frame_type = 2  # Video
    timestamp = 10000000  # 1 sec in 100ns units
    metadata_len = 0
    data_len = 32 + payload_len  # 32-byte ext header + video payload
    main_hdr = struct.pack('<BBqhI', version, frame_type, timestamp, metadata_len, data_len)
    
    # Video ext header (32 bytes)
    ext_hdr = struct.pack('<iiiiifii', codec, width, height, frn, frd, ar, flags, cs)
    return main_hdr + ext_hdr

def build_metadata_frame(xml_str):
    version = 1
    frame_type = 1  # Metadata
    timestamp = 0
    xml_bytes = xml_str.encode('utf-8') + b'\x00'  # Mandatory null terminator
    meta_len = len(xml_bytes)
    data_len = len(xml_bytes)
    main_hdr = struct.pack('<BBqhI', version, frame_type, timestamp, meta_len, data_len)
    return main_hdr + xml_bytes

def run_tests():
    print("=== OMT PROTOCOL SPECIFICATION COMPLIANCE TESTS ===")
    
    # Test 1: Video Header sizes (16 + 32 = 48 bytes)
    vid_hdr = build_video_header(0x31584D56, 1920, 1080, 30000, 1001, 1.7777778, 0, 709, 1000)
    assert len(vid_hdr) == 48, f"Expected 48, got {len(vid_hdr)}"
    print("[PASS] Test 1: Video Header length is exactly 48 bytes (16 main + 32 ext)")

    # Test 2: Codec FourCC byte layout
    codec_raw = vid_hdr[16:20]
    assert codec_raw == b'VMX1', f"Expected b'VMX1', got {codec_raw}"
    codec_int = struct.unpack('<I', codec_raw)[0]
    assert codec_int == 0x31584D56, f"Expected 0x31584D56, got {hex(codec_int)}"
    print(f"[PASS] Test 2: Codec FourCC is Little-Endian VMX1 (0x{codec_int:08X} = '{codec_raw.decode()}')")

    # Test 3: Metadata Frame with OMTInfo and null termination
    omt_info = '<OMTInfo ProductName="MIMO_NDI" Manufacturer="MIMO" Version="1.0" />'
    meta_frame = build_metadata_frame(omt_info)
    assert meta_frame[-1] == 0, "Null terminator missing!"
    expected_meta_len = len(omt_info) + 1
    v, ft, ts, mlen, dlen = struct.unpack('<BBqhI', meta_frame[:16])
    assert v == 1, "Version must be 1"
    assert ft == 1, "FrameType must be 1 (Metadata)"
    assert mlen == expected_meta_len, f"MetadataLength mismatch: {mlen} vs {expected_meta_len}"
    assert dlen == expected_meta_len, f"DataLength mismatch: {dlen} vs {expected_meta_len}"
    print("[PASS] Test 3: <OMTInfo> metadata frame formatting & null terminator")

    # Test 4: Incoming TCP fragmentation and defragmentation
    # Receiver sends <OMTSubscribe Video="true" />
    subscribe_cmd = '<OMTSubscribe Video="true" />'
    subscribe_frame = build_metadata_frame(subscribe_cmd)
    
    stream = meta_frame + subscribe_frame
    buffer = bytearray()
    received_frames = []
    
    # Deliver in tiny 7-byte chunks to test fragmentation handling
    chunk_size = 7
    for offset in range(0, len(stream), chunk_size):
        buffer.extend(stream[offset:offset + chunk_size])
        while len(buffer) >= 16:
            v, ft, ts, mlen, dlen = struct.unpack('<BBqhI', buffer[:16])
            total_needed = 16 + dlen
            if len(buffer) < total_needed:
                break
            payload = bytes(buffer[16:total_needed])
            buffer = buffer[total_needed:]
            if payload.endswith(b'\x00'):
                payload = payload[:-1]
            received_frames.append((ft, payload.decode('utf-8')))
            
    assert len(received_frames) == 2, f"Expected 2 frames, got {len(received_frames)}"
    assert received_frames[0][0] == 1, "Frame 1 must be metadata"
    assert "OMTInfo" in received_frames[0][1], "Frame 1 must be OMTInfo"
    assert received_frames[1][0] == 1, "Frame 2 must be metadata"
    assert received_frames[1][1] == subscribe_cmd, "Frame 2 must match subscribe command exactly"
    print("[PASS] Test 4: TCP frame defragmentation & <OMTSubscribe Video=\"true\" /> extraction")

    # Test 5: Dynamic dimensions support (e.g. 720p or 1080p adaptation)
    test_720p = build_video_header(0x31584D56, 1280, 720, 30000, 1001, 1.7777778, 0, 709, 250000)
    w_720, h_720 = struct.unpack('<ii', test_720p[20:28])
    assert w_720 == 1280 and h_720 == 720, f"Expected 1280x720, got {w_720}x{h_720}"
    test_1080p = build_video_header(0x31584D56, 1920, 1080, 30000, 1001, 1.7777778, 0, 709, 500000)
    w_1080, h_1080 = struct.unpack('<ii', test_1080p[20:28])
    assert w_1080 == 1920 and h_1080 == 1080, f"Expected 1920x1080, got {w_1080}x{h_1080}"
    print("[PASS] Test 5: Dynamic video dimension adaptation (1280x720 and 1920x1080)")

    print("--------------------------------------------------")
    print("RESULT: ALL 5 OMT SPEC PROTOCOL TESTS PASSED 100%!")

if __name__ == '__main__':
    run_tests()

