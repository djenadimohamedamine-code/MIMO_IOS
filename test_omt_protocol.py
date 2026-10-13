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
    xml_bytes = xml_str.encode('utf-8')  # Official libomtnet: raw UTF-8 string without null terminator
    meta_len = 0  # MetadataLength is 0 for standalone metadata frames
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

    # Test 3: Metadata Frame with OMTInfo (libomtnet standard layout)
    omt_info = '<OMTInfo ProductName="MIMO_NDI" Manufacturer="MIMO" Version="1.0" />'
    meta_frame = build_metadata_frame(omt_info)
    expected_data_len = len(omt_info.encode('utf-8'))
    v, ft, ts, mlen, dlen = struct.unpack('<BBqhI', meta_frame[:16])
    assert v == 1, "Version must be 1"
    assert ft == 1, "FrameType must be 1 (Metadata)"
    assert ts == 0, "Timestamp must be 0"
    assert mlen == 0, f"MetadataLength must be 0 for standalone metadata, got {mlen}"
    assert dlen == expected_data_len, f"DataLength mismatch: {dlen} vs {expected_data_len}"
    assert meta_frame[16:].decode('utf-8') == omt_info, "Payload must match exactly"
    print("[PASS] Test 3: <OMTInfo> metadata frame formatting (no null terminator, MetadataLength=0)")

    # Test 4: Full Receiver handshake sequence (MetadataSub + VideoSub + Quality + Tally)
    sub_meta = build_metadata_frame('<OMTSubscribe Metadata="true" />')
    sub_vid = build_metadata_frame('<OMTSubscribe Video="true" />')
    set_qual = build_metadata_frame('<OMTSettings Quality="Default" />')
    set_tally = build_metadata_frame('<OMTTally Preview="true" Program=="true" />')
    
    assert len(sub_meta) == 16 + len('<OMTSubscribe Metadata="true" />'), f"Got {len(sub_meta)}"
    assert len(sub_vid) == 16 + len('<OMTSubscribe Video="true" />'), f"Got {len(sub_vid)}"
    assert len(set_qual) == 16 + len('<OMTSettings Quality="Default" />'), f"Got {len(set_qual)}"
    assert len(set_tally) == 16 + len('<OMTTally Preview="true" Program=="true" />'), f"Got {len(set_tally)}"
    
    stream = sub_meta + sub_vid + set_qual + set_tally
    expected_stream_len = len(sub_meta) + len(sub_vid) + len(set_qual) + len(set_tally)
    assert len(stream) == expected_stream_len, f"Expected {expected_stream_len}, got {len(stream)}"
    
    # TCP defragmentation test with 11-byte chunks
    buffer = bytearray()
    received_frames = []
    chunk_size = 11
    for offset in range(0, len(stream), chunk_size):
        buffer.extend(stream[offset:offset + chunk_size])
        while len(buffer) >= 16:
            v, ft, ts, mlen, dlen = struct.unpack('<BBqhI', buffer[:16])
            total_needed = 16 + dlen
            if len(buffer) < total_needed:
                break
            payload = bytes(buffer[16:total_needed])
            buffer = buffer[total_needed:]
            received_frames.append((ft, payload.decode('utf-8')))
            
    assert len(received_frames) == 4, f"Expected 4 frames, got {len(received_frames)}"
    assert received_frames[0][1] == '<OMTSubscribe Metadata="true" />'
    assert received_frames[1][1] == '<OMTSubscribe Video="true" />'
    assert received_frames[2][1] == '<OMTSettings Quality="Default" />'
    assert received_frames[3][1] == '<OMTTally Preview="true" Program=="true" />'
    print(f"[PASS] Test 4: Receiver handshake stream (4 frames, {len(stream)} bytes) defragmentation & exact match")

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

