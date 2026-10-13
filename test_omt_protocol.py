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

def build_audio_frame(codec, sample_rate, samples_per_channel, channels, active_channels, audio_payload):
    version = 1
    frame_type = 4  # Audio
    timestamp = 10000000
    metadata_len = 0
    data_len = 24 + len(audio_payload)
    main_hdr = struct.pack('<BBqhI', version, frame_type, timestamp, metadata_len, data_len)
    
    reserved1 = 0
    audio_ext_hdr = struct.pack('<iiiiIi', codec, sample_rate, samples_per_channel, channels, active_channels, reserved1)
    return main_hdr + audio_ext_hdr + audio_payload

def decode_planar_fpa1_audio(channels, samples_per_channel, active_channels, raw_payload):
    """Simulates OMTAudioPlayer active channel bitmask decompression to non-interleaved float buffers."""
    channel_bytes = samples_per_channel * 4
    channels_data = []
    offset = 0
    for ch in range(channels):
        is_active = (active_channels & (1 << ch)) != 0
        if is_active and (offset + channel_bytes <= len(raw_payload)):
            ch_data = raw_payload[offset:offset + channel_bytes]
            offset += channel_bytes
        else:
            ch_data = bytes(channel_bytes)  # Muted: filled with zeros
        channels_data.append(ch_data)
    return channels_data

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

    # Test 6: Audio Extended Header (24 bytes) & FPA1 Codec FourCC
    fpa1_fourcc = 0x31415046  # 'FPA1' LE
    sample_rate = 48000
    samples_per_ch = 1024
    channels = 2
    active_channels = 3  # Both Ch 0 and Ch 1 active (1 | 2 = 3)
    dummy_audio = b'\x00' * (channels * samples_per_ch * 4)
    audio_frame = build_audio_frame(fpa1_fourcc, sample_rate, samples_per_ch, channels, active_channels, dummy_audio)
    
    assert len(audio_frame) == 16 + 24 + len(dummy_audio), f"Expected {16 + 24 + len(dummy_audio)}, got {len(audio_frame)}"
    v, ft, ts, mlen, dlen = struct.unpack('<BBqhI', audio_frame[:16])
    assert ft == 4, f"FrameType must be 4 (Audio), got {ft}"
    assert dlen == 24 + len(dummy_audio), f"DataLength mismatch: {dlen}"
    
    codec, sr, spc, chs, act_mask, res1 = struct.unpack('<iiiiIi', audio_frame[16:40])
    assert codec == fpa1_fourcc, f"Expected 0x31415046 ('FPA1'), got {hex(codec)}"
    assert audio_frame[16:20] == b'FPA1', f"Expected b'FPA1', got {audio_frame[16:20]}"
    assert sr == 48000, f"Expected 48000, got {sr}"
    assert spc == 1024, f"Expected 1024, got {spc}"
    assert chs == 2, f"Expected 2, got {chs}"
    assert act_mask == 3, f"Expected 3, got {act_mask}"
    assert res1 == 0, f"Expected 0, got {res1}"
    print(f"[PASS] Test 6: Audio Extended Header (24 bytes) & FPA1 Codec FourCC ('{audio_frame[16:20].decode()}' = 0x{codec:08X})")

    # Test 7: FPA1 Planar Float32 PCM deinterleaving & Active Channel Mask handling
    # Create distinct test audio buffers for Left and Right channels
    left_sample = struct.pack('<f', 0.75) * 1024
    right_sample = struct.pack('<f', -0.5) * 1024
    
    # Case A: Both channels active (mask = 3)
    payload_a = left_sample + right_sample
    decoded_a = decode_planar_fpa1_audio(2, 1024, 3, payload_a)
    assert len(decoded_a) == 2
    assert decoded_a[0] == left_sample
    assert decoded_a[1] == right_sample
    
    # Case B: Only Left channel active (mask = 1), Right channel omitted from stream
    payload_b = left_sample
    decoded_b = decode_planar_fpa1_audio(2, 1024, 1, payload_b)
    assert len(decoded_b) == 2
    assert decoded_b[0] == left_sample
    assert decoded_b[1] == bytes(1024 * 4)  # Muted channel must be zero-padded
    
    # Case C: All channels muted (mask = 0), payload is empty
    payload_c = b''
    decoded_c = decode_planar_fpa1_audio(2, 1024, 0, payload_c)
    assert len(decoded_c) == 2
    assert decoded_c[0] == bytes(1024 * 4)
    assert decoded_c[1] == bytes(1024 * 4)
    
    # Case D: Audio handshake subscription matching libomtnet dual-connection
    audio_sub = build_metadata_frame('<OMTSubscribe Audio="true" />')
    assert audio_sub[16:].decode('utf-8') == '<OMTSubscribe Audio="true" />'
    print("[PASS] Test 7: FPA1 Planar Float32 PCM decompression & ActiveChannel bitmask handling (Stereo, Left-only, Muted)")

    # Test 8: OMTSender thread-safe lifecycle state machine (start -> transmit -> stop -> restart)
    import threading
    import time
    
    class MockOMTSender:
        def __init__(self):
            self.lock = threading.Lock()
            self.encoder_lock = threading.Lock()
            self.is_running = False
            self.is_stopping = False
            self.has_pending_frame = False
            self.encoder = None
            self.frames_accepted = 0
            self.frames_rejected = 0

        def start(self):
            with self.lock:
                if self.is_running and not self.is_stopping:
                    return
                self.is_running = True
                self.is_stopping = False
                self.has_pending_frame = False
            with self.encoder_lock:
                if self.encoder is None:
                    self.encoder = "VMX1_ACTIVE"

        def send_frame(self):
            with self.lock:
                if not self.is_running or self.is_stopping or self.has_pending_frame:
                    self.frames_rejected += 1
                    return False
                self.has_pending_frame = True
            
            # Simulate async queue encode
            try:
                with self.encoder_lock:
                    if not self.is_running or self.is_stopping or self.encoder is None:
                        self.frames_rejected += 1
                        return False
                    # Safe in-memory encode
                    assert self.encoder == "VMX1_ACTIVE", "Encoder must not be destroyed during encode!"
                    time.sleep(0.001)
                    self.frames_accepted += 1
                    return True
            finally:
                with self.lock:
                    self.has_pending_frame = False

        def stop(self):
            with self.lock:
                if not self.is_running and not self.is_stopping:
                    return
                self.is_stopping = True
                self.is_running = False

            # Wait for in-flight encode and safely destroy
            with self.encoder_lock:
                self.encoder = None

            with self.lock:
                self.is_stopping = False
                self.has_pending_frame = False

    # 1. Cycle démarrage
    sender = MockOMTSender()
    sender.start()
    assert sender.is_running and sender.encoder == "VMX1_ACTIVE"

    # 2. Cycle transmission
    success = sender.send_frame()
    assert success and sender.frames_accepted == 1

    # 3. Concurrence stop() pendant transmission
    t_frame = threading.Thread(target=sender.send_frame)
    t_stop = threading.Thread(target=sender.stop)
    t_frame.start()
    t_stop.start()
    t_frame.join()
    t_stop.join()

    # Rejection post-stop
    rejected = sender.send_frame()
    assert not rejected, "Frames must be rejected after stop()"
    assert sender.encoder is None, "Encoder must be destroyed after stop()"

    # 4. Cycle redémarrage
    sender.start()
    assert sender.is_running and sender.encoder == "VMX1_ACTIVE", "Encoder must be re-instantiated on restart"
    restarted_frame = sender.send_frame()
    assert restarted_frame, "Frames must be accepted after restart"
    print("[PASS] Test 8: OMTSender lifecycle state machine & concurrent stop() / sendPixelBuffer() safety")

    print("--------------------------------------------------")
    print("RESULT: ALL 8 OMT SPEC PROTOCOL TESTS PASSED 100%!")

if __name__ == '__main__':
    run_tests()


