#!/usr/bin/env python3
"""Anlogic UART image sender. Run --help or --gui. No dependency for protocol tests."""
from __future__ import annotations
import argparse
import binascii
import hashlib
import secrets
import struct
import time
import sys
from pathlib import Path
from uart_image_metrics import TransferMetrics, format_metrics

# Optional local dependency bundle; never alters system Python packages.
if (Path(__file__).parent / '_vendor').is_dir():
    sys.path.insert(0, str(Path(__file__).parent / '_vendor'))

HELLO, BEGIN, DATA, END, ABORT, SOURCE, MODE, COMPARE, BAUD = range(1, 10)
STATUS_EXT = 10
CAPS = 11
BAUD_RATES = (115200, 921600, 2000000, 3000000)
BLOCK = 1536
PRESETS = {'Safe': (921600, 'rgb565'), 'Fast': (2000000, 'rgb565'),
           'Quality': (2000000, 'rgb888')}
DEFAULT_METRICS_DIR = Path(__file__).resolve().parents[1] / 'verification/uart_image_phase3/measurements'
ERRORS = {0: 'OK', 1: 'unknown command', 2: 'invalid upload state/session',
          3: 'resolution mismatch or video switching', 4: 'invalid length/format',
          5: 'whole-image CRC mismatch', 6: 'unexpected sequence', 7: 'busy',
          8: 'DDR fence failure or resolution changed', 9: 'no valid image'}


class DeviceError(RuntimeError):
    def __init__(self, code):
        self.code = code
        super().__init__(ERRORS.get(code, f'FPGA error {code}'))


class Phase2Required(RuntimeError):
    pass


def parse_extended_status(payload, page, token):
    """Decode V2's 24-byte status page; never interpret it as a legacy ACK."""
    if len(payload) != 24:
        raise ValueError('invalid extended response length')
    error, version, returned_page, reserved, returned_token = struct.unpack('<BBBBI', payload[:8])
    if error:
        raise DeviceError(error)
    if (version, returned_page, reserved, returned_token) != (2, page, 0, token):
        raise ValueError('STATUS_EXT schema/page/snapshot mismatch')
    if page == 0:
        keys = ('resolution', 'desired_source', 'active_source', 'compare',
                'requested_mode', 'active_mode', 'display_valid', 'transition_active',
                'displayed_generation', 'displayed_image_id')
        values = struct.unpack('<8BII', payload[8:])
    elif page in (1, 2):
        keys = ('front_valid', 'front_slot', 'slot_states', 'format', 'generation',
                'image_id', 'width', 'height')
        values = struct.unpack('<4BIIHH', payload[8:])
    elif page == 3:
        keys = ('upload_active', 'target_resolution', 'format', 'upload_phase',
                'session_id', 'received_bytes', 'expected_sequence')
        values = struct.unpack('<4BIII', payload[8:])
    else:
        raise ValueError('invalid STATUS_EXT page')
    return dict(zip(keys, values))


def encode_packet(command, session=0, sequence=0, payload=b'', flags=0):
    if len(payload) > BLOCK:
        raise ValueError('payload exceeds 1536 bytes')
    header = struct.pack('<BBBBIIH', 1, command, flags, 0, session, sequence, len(payload))
    header += struct.pack('<H', binascii.crc_hqx(header, 0xffff))
    body = header + payload
    body += struct.pack('<I', binascii.crc32(body))
    # Escape 0x7d first so newly inserted escape bytes are not escaped again.
    # bytes.replace runs in C; wire representation is unchanged.
    return b'\x7e' + body.replace(b'\x7d', b'\x7d\x5d').replace(b'\x7e', b'\x7d\x5e') + b'\x7e'


def decode_packet(body):
    if len(body) < 20:
        raise ValueError('short packet')
    version, command, flags, reserved, session, sequence, size, hcrc = struct.unpack('<BBBBIIHH', body[:16])
    if version != 1 or reserved or size > BLOCK or len(body) != size + 20:
        raise ValueError('invalid header/length')
    if binascii.crc_hqx(body[:14], 0xffff) != hcrc:
        raise ValueError('header CRC')
    if binascii.crc32(body[:-4]) != struct.unpack('<I', body[-4:])[0]:
        raise ValueError('packet CRC')
    return command, session, sequence, body[16:-4], flags


class Decoder:
    def __init__(self):
        self.data = bytearray()
        self.active = False
        self.escape = False
        self.crc_errors = 0
        self.invalid_frames = 0

    def feed(self, data):
        packets = []
        for value in data:
            if value == 0x7e:
                if self.active and self.data and not self.escape:
                    try:
                        packets.append(decode_packet(bytes(self.data)))
                    except ValueError as exc:
                        self.invalid_frames += 1
                        self.crc_errors += int('CRC' in str(exc))
                elif self.active and self.data and self.escape:
                    self.invalid_frames += 1
                self.data.clear()
                self.active, self.escape = True, False
            elif self.active:
                if value == 0x7d and not self.escape:
                    self.escape = True
                else:
                    self.data.append(value ^ 0x20 if self.escape else value)
                    self.escape = False
                    if len(self.data) > BLOCK + 20:
                        self.active = False
                        self.invalid_frames += 1
        return packets


def parse_status(payload):
    if len(payload) != 24:
        raise ValueError('invalid response length')
    values = struct.unpack('<BBBBIIIIBBBB', payload)
    return dict(zip(('error', 'resolution', 'source', 'compare', 'next_sequence',
                     'received_bytes', 'ready_image_id', 'displayed_image_id',
                     'mode', 'fast_baud', 'image_valid', 'reserved'), values))


def prepare_image(path, resolution, pixel_format='rgb888', fit='contain', reference=None):
    if resolution not in (720, 1080) or pixel_format not in ('rgb888', 'rgb565') or fit not in ('contain', 'cover', 'stretch'):
        raise ValueError('unsupported resolution, pixel format or image fit')
    from PIL import Image, ImageOps
    size = (1920, 1080) if resolution == 1080 else (1280, 720)
    with Image.open(path) as original:
        oriented = ImageOps.exif_transpose(original).convert('RGBA')
        background = Image.new('RGBA', oriented.size, (0, 0, 0, 255))
        background.alpha_composite(oriented)
        rgb = background.convert('RGB')
        method = Image.Resampling.LANCZOS
        if fit == 'stretch':
            rgb = rgb.resize(size, method)
        elif fit == 'cover':
            rgb = ImageOps.fit(rgb, size, method=method)
        else:
            resized = ImageOps.contain(rgb, size, method=method)
            rgb = Image.new('RGB', size)
            rgb.paste(resized, ((size[0]-resized.width)//2, (size[1]-resized.height)//2))
        payload = rgb.tobytes()
    if pixel_format == 'rgb565':
        raw = bytearray(size[0] * size[1] * 2)
        reconstructed = bytearray(len(payload))
        for index in range(size[0] * size[1]):
            r, g, b = payload[index*3:index*3+3]
            r5, g6, b5 = r >> 3, g >> 2, b >> 3
            value = (r5 << 11) | (g6 << 5) | b5
            struct.pack_into('<H', raw, index*2, value)
            reconstructed[index*3:index*3+3] = bytes(((r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)))
        payload = bytes(raw)
        rgb = Image.frombytes('RGB', size, bytes(reconstructed))
    if reference:
        rgb.save(reference)
    return payload, size


def begin_payload(payload, size, pixel_format, image_id):
    return struct.pack('<HHB3xIII', *size, int(pixel_format == 'rgb565'), len(payload), image_id, binascii.crc32(payload))


def content_image_id(payload, size, pixel_format):
    """Stable 32-bit fingerprint of the exact FPGA input and its interpretation.

    The existing wire/status field is 32-bit, so this is a cache convenience,
    not a collision-free identity. --force-upload bypasses cache checks.
    """
    digest = hashlib.sha256(b'UART_IMAGE_INPUT_V1\0' +
        struct.pack('<HHB', *size, int(pixel_format == 'rgb565')) + payload).digest()
    return int.from_bytes(digest[:4], 'little')


def export_file(path, payload, size, pixel_format, image_id):
    """SSCOM: binary 115200 8N1. Padding supplies processing time, no ACK required.

    If the DDR blocks longer than the padding budget, the upload is rejected;
    the old front buffer stays displayed. Use reliable mode for retransmission.
    """
    session = secrets.randbits(32)
    padding = b'\x7e' * 128
    with Path(path).open('wb') as stream:
        stream.write(encode_packet(BEGIN, session, 0, begin_payload(payload, size, pixel_format, image_id), 1) + padding)
        chunks = (len(payload) + BLOCK-1)//BLOCK
        for seq in range(chunks):
            stream.write(encode_packet(DATA, session, seq, payload[seq*BLOCK:(seq+1)*BLOCK], 1) + padding)
        stream.write(encode_packet(END, session, chunks, flags=1) + b'\x7e'*2048)
        stream.write(encode_packet(SOURCE, session, chunks+1, b'\x01', 1) + padding)


class Client:
    def __init__(self, port, baud=921600, timeout=2.0):
        if baud not in BAUD_RATES:
            raise ValueError('unsupported baud rate')
        import serial
        self.serial = serial.Serial(port, 115200, timeout=0.05, write_timeout=5,
                                    rtscts=False, dsrdtr=False, xonxoff=False)
        self.decoder = Decoder()
        self.session = secrets.randbits(32)
        self.control_seq = 0x80000000
        self.timeout = timeout
        self.last_status = {}
        self.ext_supported = None
        self.metrics = None
        self.last_metrics = None
        self.metrics_history = []
        self.metrics_dir = None
        self.metrics_callback = None
        self.baseline_flush = False
        self.force_upload = False
        self.target_baud = baud
        self.window = 1
        try:
            self.synchronize(baud)
        except Exception:
            self.close()
            raise

    def synchronize(self, baud):
        # Reconnect may overlap the FPGA's five-second idle fallback.
        # Prefer the requested rate, retry both, and finish at the reset
        # rate. Each probe remains bounded; no image/control is sent here.
        other = 115200 if baud != 115200 else 921600
        extra = tuple(speed for speed in BAUD_RATES if speed not in (baud, other))
        for speed in (baud, other, baud, other, *extra, 115200):
            self.serial.baudrate = speed
            time.sleep(0.03)
            self.serial.reset_input_buffer()
            self.decoder = Decoder()
            try:
                status = self.command(HELLO, retries=1)
                break
            except TimeoutError:
                continue
        else:
            raise TimeoutError('FPGA did not respond after bounded baud probes; check COM port, USB driver, cable and board power')
        if self.serial.baudrate != baud:
            try:
                self.command(BAUD, bytes((BAUD_RATES.index(baud),)))
            except DeviceError as exc:
                if exc.code == 4 and baud > 921600:
                    raise RuntimeError('FPGA rejected high-speed BAUD; load the updated bitstream or select 921600') from exc
                raise
            time.sleep(0.03)
            self.serial.baudrate = baud
            status = self.command(HELLO)
        return status

    def ensure_ready(self, baud):
        """Probe before a GUI action; recover idle fallback on the same port."""
        try:
            return self.command(HELLO, retries=1)
        except TimeoutError:
            return self.synchronize(baud)

    def close(self):
        self.serial.close()

    def transact(self, command, sequence, payload=b'', retries=5, busy_timeout=10.0, flags=0):
        wire = encode_packet(command, self.session, sequence, payload, flags)
        attempts = 0
        busy_deadline = None
        sends = 0
        metrics = getattr(self, 'metrics', None)
        while attempts < retries:
            if busy_deadline is not None and time.monotonic() >= busy_deadline:
                raise TimeoutError(f'command {command}: FPGA remained BUSY for {busy_timeout}s')
            row = metrics.begin_attempt(command, sequence, len(payload), len(wire), sends) if metrics else None
            sends += 1
            try:
                written = self.serial.write(wire)
                if written != len(wire):
                    raise OSError(f'short serial write: {written}/{len(wire)} bytes')
                if row is not None:
                    row['send_finish_time'] = time.monotonic()
                # Legacy A/B measurement only. ACK already proves transmission;
                # the optimized path need not wait for OS flush on every packet.
                if getattr(self, 'baseline_flush', False):
                    self.serial.flush()
                    if row is not None:
                        row['flush_finish_time'] = time.monotonic()
            except Exception:
                if row is not None:
                    row['outcome'] = 'write_error'
                raise
            # write() can return with bytes queued in the driver. Include the
            # full 8N1 wire duration in the response deadline without flush().
            deadline = time.monotonic() + self.timeout + len(wire)*10/getattr(self.serial, 'baudrate', 921600)
            if busy_deadline is not None:
                deadline = min(deadline, busy_deadline)
            busy = False
            while time.monotonic() < deadline:
                old_crc, old_invalid = self.decoder.crc_errors, self.decoder.invalid_frames
                try:
                    packets = self.decoder.feed(self.serial.read(max(1, self.serial.in_waiting)))
                except Exception:
                    if row is not None:
                        row['outcome'] = 'read_error'
                    raise
                if metrics:
                    metrics.rx_crc_errors += self.decoder.crc_errors - old_crc
                    metrics.rx_invalid_frames += self.decoder.invalid_frames - old_invalid
                for cmd, session, seq, body, _flags in packets:
                    if (cmd, session, seq) != (command | 0x80, self.session, sequence):
                        continue
                    if len(body) != 24:
                        if row is not None:
                            row['outcome'] = 'invalid_response'
                        raise ValueError('invalid response length')
                    if metrics:
                        metrics.acknowledge(row, body[0])
                    if body[0] == 7:
                        if busy_deadline is None:
                            busy_deadline = time.monotonic() + busy_timeout
                        busy = True
                        break
                    if body[0]:
                        raise DeviceError(body[0])
                    if command == CAPS:
                        if body != bytes(16) + b'ANW8\x01\x00\x01\x08':
                            raise ValueError('unsupported window capability schema')
                        return dict(version=1, windows=(1,8))
                    if command == STATUS_EXT:
                        page, token = struct.unpack('<BI', payload)
                        return parse_extended_status(body, page, token)
                    status = parse_status(body)
                    self.last_status = status
                    return status
                if busy:
                    break
            if busy:
                time.sleep(min(0.05, max(0, busy_deadline-time.monotonic())))
            else:
                if row is not None:
                    row['outcome'] = 'timeout'
                attempts += 1
        raise TimeoutError(f'command {command}, sequence {sequence}: no ACK after {retries} attempts')

    def command(self, command, payload=b'', retries=5):
        self.control_seq = (self.control_seq + 1) & 0xffffffff
        return self.transact(command, self.control_seq, payload, retries)

    def require_window(self):
        window = getattr(self, 'window', 1)
        if window not in (1,8):
            raise ValueError('supported windows are 1 and 8; Window16 awaits board validation')
        if window == 8:
            try:
                self.command(CAPS)
            except DeviceError as exc:
                if exc.code == 1:
                    raise RuntimeError('Window8 requires the new FPGA bitstream; select Safe / Window1 for this firmware') from exc
                raise

    def upload_window(self, payload, progress):
        """Window8 cumulative ACK / Go-Back-N. FPGA never buffers out of order.

        Outstanding wire packets stay on the PC until next_sequence commits
        them. Timeouts retransmit only the unconfirmed suffix, at most 5 sends
        per packet. The wire queue duration is included in every deadline.
        """
        blocks = (len(payload)+BLOCK-1)//BLOCK
        base = next_send = 0
        pending = {}
        attempts = {}
        rows = {}
        next_update = 0.0
        baud = getattr(self.serial, 'baudrate', 921600)
        deadline = time.monotonic()+self.timeout

        def send(sequence):
            count = attempts.get(sequence,0)
            if count >= 5:
                raise TimeoutError(f'Window8 sequence {sequence}: no cumulative ACK after 5 sends')
            chunk = payload[sequence*BLOCK:(sequence+1)*BLOCK]
            wire = pending.setdefault(sequence,encode_packet(DATA,self.session,sequence,chunk,2))
            row = self.metrics.begin_attempt(DATA,sequence,len(chunk),len(wire),count)
            rows[sequence] = row
            attempts[sequence] = count+1
            try:
                written = self.serial.write(wire)
                if written != len(wire):
                    raise OSError(f'short serial write: {written}/{len(wire)} bytes')
                row['send_finish_time'] = time.monotonic()
                if getattr(self,'baseline_flush',False):
                    self.serial.flush()
                    row['flush_finish_time'] = time.monotonic()
            except Exception:
                row['outcome'] = 'write_error'
                raise

        while base < blocks:
            added = False
            while next_send < min(base+8,blocks):
                send(next_send)
                next_send += 1
                added = True
            if added:
                deadline = time.monotonic()+self.timeout+sum(len(w) for w in pending.values())*10/baud
            old_crc,old_invalid = self.decoder.crc_errors,self.decoder.invalid_frames
            try:
                packets = self.decoder.feed(self.serial.read(max(1,self.serial.in_waiting)))
            except Exception:
                for row in rows.values():
                    row['outcome'] = 'read_error'
                raise
            self.metrics.rx_crc_errors += self.decoder.crc_errors-old_crc
            self.metrics.rx_invalid_frames += self.decoder.invalid_frames-old_invalid
            for cmd,session,sequence,body,_ in packets:
                if cmd != DATA|0x80 or session != self.session or not 0 <= sequence < next_send:
                    continue
                status = parse_status(body)
                if status['error'] not in (0,6):
                    if sequence in rows:
                        self.metrics.acknowledge(rows[sequence],status['error'])
                    raise DeviceError(status['error'])
                frontier = status['next_sequence']
                if not 0 <= frontier <= next_send or status['received_bytes'] != min(frontier*BLOCK,len(payload)):
                    raise RuntimeError('invalid cumulative ACK frontier/byte count')
                self.metrics.window_responses += 1
                self.metrics.window_sequence_errors += int(status['error']==6)
                if frontier <= base:
                    continue  # duplicate/late ACK must not reset the timeout
                for seq in range(base,frontier):
                    self.metrics.acknowledge(rows.pop(seq),0)
                    pending.pop(seq)
                base = frontier
                self.last_status = status
                deadline = time.monotonic()+self.timeout+sum(len(w) for w in pending.values())*10/baud
            now = time.monotonic()
            if now >= next_update or base == blocks:
                state = self.metrics.snapshot()
                progress(format_metrics(state))
                callback = getattr(self,'metrics_callback',None)
                if callback:
                    callback(state)
                next_update = now+.25
            if base < blocks and now >= deadline:
                for seq in range(base,next_send):
                    rows[seq]['outcome'] = 'timeout'
                    send(seq)
                deadline = time.monotonic()+self.timeout+sum(len(w) for w in pending.values())*10/baud

    def status_extended(self):
        if self.ext_supported is False:
            return None
        # Restart a complete snapshot once if it expired; never join mixed pages.
        for attempt in range(2):
            token = secrets.randbits(32) or 1
            try:
                pages = [self.command(STATUS_EXT, struct.pack('<BI', page, token)) for page in range(4)]
            except DeviceError as exc:
                if exc.code == 1:
                    self.ext_supported = False
                    return None
                if exc.code == 2 and attempt == 0:
                    continue
                raise
            self.ext_supported = True
            return dict(snapshot_token=token, display=pages[0], img720=pages[1],
                        img1080=pages[2], upload=pages[3])
        raise RuntimeError('could not obtain a coherent STATUS_EXT snapshot')

    def upload_image(self, payload, size, pixel_format, image_id, progress=print):
        """Measure each transfer, including failures; persist outside DATA loop."""
        self.metrics = TransferMetrics(getattr(self.serial, 'baudrate', 921600),
            len(payload), size[1], pixel_format, image_id, getattr(self, 'baseline_flush', False))
        self.metrics.window = getattr(self, 'window', 1)
        try:
            receipt = self._upload_image(payload, size, pixel_format, image_id, progress)
            self.metrics.finish('cached' if receipt.get('cached') else 'ready')
            return receipt
        except Exception as exc:
            self.metrics.finish('failed', exc)
            raise
        finally:
            self.last_metrics = self.metrics.snapshot()
            if not hasattr(self, 'metrics_history'):
                self.metrics_history = []
            self.metrics_history.append(self.last_metrics)
            callback = getattr(self, 'metrics_callback', None)
            if callback:
                callback(self.last_metrics)
            try:
                directory = getattr(self, 'metrics_dir', None)
                if directory:
                    progress(f'Performance report: {self.metrics.save(directory)}')
            except OSError as exc:
                progress(f'WARNING: could not save performance report: {exc}')
            finally:
                self.metrics = None

    def _upload_image(self, payload, size, pixel_format, image_id, progress=print):
        """Return a READY receipt, leaving Source, Mode and View untouched."""
        if size not in ((1280, 720), (1920, 1080)) or pixel_format not in ('rgb888', 'rgb565'):
            raise ValueError('unsupported upload size/format')
        if len(payload) != size[0]*size[1]*(2 if pixel_format == 'rgb565' else 3):
            raise ValueError('payload length does not match size/format')
        # Conversion or saving PNG references can outlast the idle baud timer.
        if hasattr(self, 'target_baud'):
            self.ensure_ready(self.target_baud)
        before = self.status_extended()
        resolution = size[1]
        if before is not None and not getattr(self, 'force_upload', False):
            entry = before[f'img{resolution}']
            # Only content-derived IDs are eligible, never caller-chosen IDs.
            if (image_id == content_image_id(payload, size, pixel_format) and
                    entry['front_valid'] == 1 and entry['image_id'] == image_id and
                    (entry['width'], entry['height']) == size and
                    entry['format'] == int(pixel_format == 'rgb565')):
                progress(f'IMG{resolution} READY: Image already cached on FPGA (id={image_id:08x})')
                return dict(resolution=resolution, image_id=image_id,
                            generation=entry['generation'], cached=True)
        if before is None:
            legacy = self.command(HELLO)
            if resolution != (1080 if legacy['resolution'] else 720):
                raise Phase2Required('Legacy FPGA requires image resolution to match SW4')
        self.require_window()
        # Distinct image transactions must not reuse the active/completed session.
        previous_session = self.session
        self.session = secrets.randbits(32) or 1
        if self.session == previous_session:
            self.session = (previous_session + 1) & 0xffffffff or 1
        started = time.monotonic()
        begin = self.transact(BEGIN, 0, begin_payload(payload, size, pixel_format, image_id),
                              flags=2 if getattr(self,'window',1)==8 else 0)
        blocks = (len(payload) + BLOCK-1)//BLOCK
        if begin['next_sequence'] != 0 or begin['received_bytes'] != 0:
            raise ValueError('invalid resume sequence')
        next_update = started
        if getattr(self,'window',1)==8:
            self.upload_window(payload,progress)
        for seq in range(begin['next_sequence'], blocks) if getattr(self,'window',1)==1 else ():
            result = self.transact(DATA, seq, payload[seq*BLOCK:(seq+1)*BLOCK])
            if (result['next_sequence'] != seq+1 or
                    result['received_bytes'] != min((seq+1)*BLOCK, len(payload))):
                raise RuntimeError('DATA ACK does not confirm contiguous image bytes')
            now = time.monotonic()
            if now >= next_update or seq == blocks-1:
                state = self.metrics.snapshot()
                progress(format_metrics(state))
                callback = getattr(self, 'metrics_callback', None)
                if callback:
                    callback(state)
                next_update = now + 0.25
        result = self.transact(END, blocks)
        if result['ready_image_id'] != image_id:
            raise RuntimeError('END acknowledged a different image; READY not confirmed')
        receipt = dict(resolution=resolution, image_id=image_id, generation=None)
        if before is not None:
            after = self.status_extended()
            if after is None:
                raise RuntimeError('FPGA lost Phase 2 capability during upload')
            descriptor = after[f'img{resolution}']
            expected_generation = (before[f'img{resolution}']['generation'] + 1) & 0xffffffff
            if (descriptor['front_valid'] != 1 or descriptor['image_id'] != image_id or
                    descriptor['generation'] != expected_generation or
                    (descriptor['width'], descriptor['height']) != size or
                    descriptor['format'] != int(pixel_format == 'rgb565')):
                raise RuntimeError(f'{resolution} cache descriptor does not confirm this upload')
            receipt['generation'] = descriptor['generation']
        elapsed = time.monotonic()-self.metrics.started
        transferred = max(0, len(payload)-begin['next_sequence']*BLOCK)
        progress(f'IMG{resolution} READY image={image_id}, elapsed={elapsed:.2f}s, '
                 f'payload={transferred/1024:.1f} KiB, effective={transferred/1024/max(elapsed,1e-9):.1f} KiB/s')
        return receipt

    def select_source(self, uart=True):
        return self.command(SOURCE, bytes((int(uart),)))

    def wait_displayed(self, receipt, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            extended = self.status_extended()
            if extended is not None:
                state = extended['display']
                matches = (state['display_valid'] == 1 and state['active_source'] == 1 and
                           state['resolution'] == int(receipt['resolution'] == 1080) and
                           state['displayed_image_id'] == receipt['image_id'] and
                           state['displayed_generation'] == receipt['generation'])
            else:
                if receipt['generation'] is not None:
                    raise RuntimeError('Phase 2 display confirmation became unavailable')
                state = self.command(HELLO)
                matches = (state['image_valid'] == 1 and state['source'] == 1 and
                           state['resolution'] == int(receipt['resolution'] == 1080) and
                           state['displayed_image_id'] == receipt['image_id'])
            if matches:
                return state
            time.sleep(0.03)
        raise TimeoutError('Image is READY, but DISPLAYED was not confirmed; cache was not erased')

    def upload(self, payload, size, pixel_format, image_id, progress=print):
        """Legacy single-image UI: upload, explicitly select UART, then display."""
        receipt = self.upload_image(payload, size, pixel_format, image_id, progress)
        self.command(SOURCE, b'\x01')
        status = self.wait_displayed(receipt)
        progress(f'DISPLAYED image={image_id}')
        return status

    def preload_both(self, path, pixel_format='rgb888', fit='contain', reference_dir=None, progress=print):
        if self.status_extended() is None:
            raise Phase2Required('This FPGA has no Phase 2 STATUS_EXT; --both is disabled. Single-image upload is available.')
        path = Path(path)
        directory = Path(reference_dir) if reference_dir else path.parent
        directory.mkdir(parents=True, exist_ok=True)
        receipts = {}
        for resolution in (720, 1080):
            reference = directory/f'{path.stem}_{resolution}_reference.png'
            try:
                payload, size = prepare_image(path, resolution, pixel_format, fit, reference)
                receipts[resolution] = self.upload_image(payload, size, pixel_format,
                    content_image_id(payload, size, pixel_format), progress)
                progress(f'Exact FPGA input reference: {reference}')
            except Exception:
                for ready in receipts:
                    progress(f'IMG{ready} READY (previous upload completed)')
                progress(f'IMG{resolution} FAILED; no cache-clear or ABORT command was sent')
                raise
        snapshot = self.status_extended()
        if snapshot is None:
            raise RuntimeError('Phase 2 cache query became unavailable')
        for resolution, receipt in receipts.items():
            entry = snapshot[f'img{resolution}']
            if (entry['front_valid'], entry['image_id'], entry['generation']) != (1, receipt['image_id'], receipt['generation']):
                raise RuntimeError(f'IMG{resolution} changed before final dual-cache confirmation')
        progress('IMG720 READY; IMG1080 READY')
        return receipts


class ConnectionSession:
    """One GUI connection; callers serialize acquire/action/close operations."""
    def __init__(self):
        self.client = None
        self.config = None

    def close(self):
        client, self.client = self.client, None
        self.config = None
        if client is not None:
            client.close()

    def acquire(self, port, baud):
        config = (port, baud)
        try:
            if self.client is None or self.config != config:
                self.close()
                self.client = Client(port, baud)
                self.config = config
                return self.client, self.client.last_status
            return self.client, self.client.ensure_ready(baud)
        except Exception:
            self.close()
            raise


def apply_view_controls(client, mode, compare):
    """Apply the selected algorithm and view before a source switch/display."""
    if mode is not None:
        client.command(MODE, bytes((int(mode),)))
    if compare is not None:
        client.command(COMPARE, bytes((('processed', 'original', 'wipe').index(compare),)))


def resolve_upload_resolution(selection, status):
    """Resolve the GUI single-upload target, with SW4 compatibility fallback."""
    if selection in ('720', '1080'):
        return int(selection)
    return 1080 if status.get('resolution', 0) else 720


def gui():
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox
    import threading
    import queue
    from serial.tools import list_ports
    root=tk.Tk();root.title('Anlogic UART image / Phase 3 throughput');root.geometry('1040x690')
    values={name:tk.StringVar(value=default) for name,default in
            [('port',''),('image',''),('format','rgb565'),('mode','0'),('compare','processed'),('baud','921600'),('preset','Safe'),('window','1'),('resolution','auto')]}
    for row,(label,name) in enumerate([('COM port','port'),('Image','image'),('Pixel format','format'),('Baud','baud'),('Algorithm 0-17','mode'),('Compare','compare')]):
        ttk.Label(root,text=label).grid(row=row,column=0,padx=8,pady=6,sticky='w')
        options={'port':[p.device for p in list_ports.comports()], 'format':['rgb888','rgb565'], 'baud':[str(b) for b in BAUD_RATES],
                 'mode':[str(n) for n in range(18)],'compare':['processed','original','wipe']}
        entry=ttk.Combobox(root,textvariable=values[name],values=options[name],state='readonly') if name in options else ttk.Entry(root,textvariable=values[name],width=48)
        entry.grid(row=row,column=1,sticky='ew')
        if name in ('format','baud'):
            entry.bind('<<ComboboxSelected>>',lambda _:values['preset'].set('Custom'))
    ttk.Button(root,text='Browse',command=lambda:values['image'].set(filedialog.askopenfilename())).grid(row=1,column=2)
    window_entry=ttk.Combobox(root,textvariable=values['window'],values=['1','8'],state='readonly',width=8)
    window_entry.grid(row=2,column=2,sticky='w')
    window_entry.bind('<<ComboboxSelected>>',lambda _:values['preset'].set('Custom'))
    ttk.Label(root,text='Window (new FPGA required for 8)').grid(row=3,column=2,sticky='w')
    ttk.Label(root,text='Single upload resolution').grid(row=4,column=2,sticky='w')
    resolution_frame=ttk.Frame(root)
    resolution_frame.grid(row=5,column=2,sticky='w')
    resolution_buttons={}
    resolution_style=ttk.Style(root)
    resolution_style.configure('Resolution.TButton',padding=(5,1))
    resolution_style.configure('ResolutionSelected.TButton',padding=(5,1),background='#cfe8ff')
    resolution_style.map('ResolutionSelected.TButton',
                         background=[('active','#cfe8ff'),('pressed','#cfe8ff')])
    def choose_resolution(value):
        values['resolution'].set(value)
        for option, button in resolution_buttons.items():
            button.configure(style='ResolutionSelected.TButton' if option == value else 'Resolution.TButton')

    for label, value in (('720p','720'),('1080p','1080'),('Follow SW4','auto')):
        button=ttk.Button(resolution_frame,text=label,width=6,style='Resolution.TButton',
                          command=lambda selected=value:choose_resolution(selected))
        button.pack(side='left',padx=(0,2))
        resolution_buttons[value]=button
    choose_resolution(values['resolution'].get())
    ttk.Label(root,text='Profile').grid(row=6,column=0,sticky='w',padx=8)
    preset=ttk.Combobox(root,textvariable=values['preset'],values=[*PRESETS,'Custom'],state='readonly')
    preset.grid(row=6,column=1,sticky='ew')
    def choose_preset(_=None):
        if values['preset'].get() in PRESETS:
            baud,fmt=PRESETS[values['preset'].get()]
            values['baud'].set(str(baud));values['format'].set(fmt)
            values['window'].set('1' if values['preset'].get()=='Safe' else '8')
    preset.bind('<<ComboboxSelected>>',choose_preset)
    force=tk.BooleanVar(value=False)
    ttk.Checkbutton(root,text='Force upload (ignore cache)',variable=force).grid(row=6,column=2)
    performance=tk.StringVar(value='Safe: Window1 | Fast/Quality: 2M + Window8, new FPGA required; hardware validation pending')
    cache_state=tk.StringVar(value='IMG720: UNKNOWN | IMG1080: UNKNOWN')
    ttk.Label(root,textvariable=performance,wraplength=1000).grid(row=9,column=0,columnspan=3,sticky='w',padx=8,pady=6)
    ttk.Label(root,textvariable=cache_state).grid(row=10,column=0,columnspan=3,sticky='w',padx=8)
    log=tk.Text(root,height=17,width=110);log.grid(row=11,column=0,columnspan=3,padx=8,pady=8)
    messages=queue.Queue();busy=False;closing=False
    image_states={720:'UNKNOWN',1080:'UNKNOWN'}
    connection=ConnectionSession()
    def poll():
        nonlocal busy
        while not messages.empty():
            kind,text=messages.get()
            if kind=='done': busy=False
            elif kind=='metrics': performance.set(text)
            elif kind=='image_state':
                resolution,outcome=text
                image_states[resolution]=outcome
                cache_state.set(' | '.join(f'IMG{res}: {image_states[res]}' for res in (720,1080)))
            elif kind=='cache':
                cache_state.set(text)
                image_states.update({720:'UNKNOWN',1080:'UNKNOWN'})
            elif kind=='cache_snapshot':
                image_states.update(text)
                cache_state.set(' | '.join(f'IMG{res}: {image_states[res]}' for res in (720,1080)))
            else:
                log.insert('end',text+'\n');log.see('end')
                if int(log.index('end-1c').split('.')[0]) > 2000:
                    log.delete('1.0','501.0')
        root.after(250,poll)
    def start(action):
        nonlocal busy
        if busy: return
        opts={k:v.get() for k,v in values.items()}
        opts['force']=force.get()
        if not opts['port'] and action!='disconnect': messagebox.showerror('COM','Select a COM port');return
        if action in ('upload','both') and not opts['image']:
            messagebox.showerror('Image','Select an image');return
        busy=True
        def work():
            try:
                if action == 'disconnect':
                    connection.close()
                    messages.put(('log','Serial port released.'))
                    return
                client,status=connection.acquire(opts['port'],int(opts['baud']))
                client.metrics_dir=DEFAULT_METRICS_DIR
                client.force_upload=opts['force']
                client.window=int(opts['window'])
                def update_metrics(state):
                    messages.put(('metrics',format_metrics(state)))
                    outcome={'ready':'READY','cached':'READY (cached)',
                             'failed':'UPLOAD FAILED; previous cache retained'}.get(state['outcome'],'UPLOADING')
                    messages.put(('image_state',(state['resolution'],outcome)))
                client.metrics_callback=update_metrics
                messages.put(('log',f'Status: {status}'))
                if action == 'both':
                    client.preload_both(opts['image'],opts['format'],progress=lambda x:messages.put(('log',x)))
                    apply_view_controls(client, opts['mode'], opts['compare'])
                    messages.put(('log','Preload complete. Selected Mode and Compare will be used for the next displayed frame.'))
                elif action == 'upload':
                    resolution=resolve_upload_resolution(opts['resolution'], status)
                    ref=Path(opts['image']).with_name(Path(opts['image']).stem+'_fpga_reference.png')
                    payload,size=prepare_image(opts['image'],resolution,opts['format'],reference=ref)
                    client.upload(payload,size,opts['format'],content_image_id(payload,size,opts['format']),lambda x:messages.put(('log',x)))
                    apply_view_controls(client, opts['mode'], opts['compare'])
                    messages.put(('log',f'Reference saved: {ref}'))
                elif action == 'controls':
                    apply_view_controls(client, opts['mode'], opts['compare'])
                    messages.put(('log','Controls applied at the next frame boundary.'))
                elif action in ('camera','uart'):
                    if action == 'uart':
                        # A view selected in the GUI must take effect when the
                        # user switches to the uploaded image. Upload itself
                        # intentionally preserves the currently displayed view.
                        apply_view_controls(client, opts['mode'], opts['compare'])
                    client.select_source(action == 'uart')
                    messages.put(('log',f'Source requested: {action}'))
                snapshot=client.status_extended()
                if snapshot:
                    messages.put(('cache_snapshot',{
                        res:'READY' if snapshot[f'img{res}']['front_valid'] else 'EMPTY'
                        for res in (720,1080)}))
            except Exception as exc:
                connection.close()
                messages.put(('cache','Cache state unconfirmed; see READY receipts in log'))
                messages.put(('log',f'ERROR: {exc}'))
            finally:
                if closing: connection.close()
                messages.put(('done',''))
        threading.Thread(target=work,daemon=True).start()
    ttk.Button(root,text='Upload image',command=lambda:start('upload')).grid(row=7,column=0)
    ttk.Button(root,text='Apply mode / compare',command=lambda:start('controls')).grid(row=7,column=1)
    ttk.Button(root,text='Preload 720 + 1080',command=lambda:start('both')).grid(row=7,column=2)
    ttk.Button(root,text='Show Camera',command=lambda:start('camera')).grid(row=8,column=0)
    ttk.Button(root,text='Show UART',command=lambda:start('uart')).grid(row=8,column=1)
    ttk.Button(root,text='Disconnect',command=lambda:start('disconnect')).grid(row=8,column=2)
    def shutdown():
        nonlocal closing
        closing=True
        if not busy: connection.close()
        root.destroy()
    root.protocol('WM_DELETE_WINDOW',shutdown)
    root.columnconfigure(1,weight=1);poll();root.mainloop()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--gui',action='store_true');ap.add_argument('--port')
    ap.add_argument('--image',type=Path);ap.add_argument('--baud',type=int,choices=BAUD_RATES)
    ap.add_argument('--resolution',type=int,choices=(720,1080));ap.add_argument('--format',choices=('rgb888','rgb565'))
    ap.add_argument('--preset',choices=(*PRESETS,'Custom'),default='Safe',help='Fast/Quality use 2M + Window8; new FPGA required, board validation pending')
    ap.add_argument('--window',type=int,choices=(1,8),help='override preset; Window8 requires new FPGA firmware')
    ap.add_argument('--force-upload',action='store_true',help='bypass FPGA image cache (required for benchmarks)')
    ap.add_argument('--baseline-flush',action='store_true',help='A/B measurement: retain legacy per-packet flush')
    ap.add_argument('--metrics-dir',type=Path,default=DEFAULT_METRICS_DIR,help='save per-image JSON and per-attempt CSV, including failures')
    ap.add_argument('--fit',choices=('contain','cover','stretch'),default='contain');ap.add_argument('--reference',type=Path)
    ap.add_argument('--export',type=Path,help='export SSCOM binary .aimg (115200 only)')
    ap.add_argument('--mode',type=int,choices=range(18));ap.add_argument('--compare',choices=('processed','original','wipe'))
    ap.add_argument('--source',choices=('camera','uart'));ap.add_argument('--status',action='store_true')
    ap.add_argument('--both',action='store_true',help='preload both resolutions; requires Phase 2 firmware')
    ap.add_argument('--show',action='store_true',help='select UART after --both')
    ap.add_argument('--preload',action='store_true',help='single image: only wait for READY, preserve source')
    ap.add_argument('--reference-dir',type=Path,help='directory for the two --both reference images')
    args=ap.parse_args()
    preset_baud,preset_format=PRESETS.get(args.preset,(921600,'rgb888'))
    args.baud=args.baud if args.baud is not None else preset_baud
    args.format=args.format if args.format is not None else preset_format
    args.window=args.window if args.window is not None else (8 if args.preset in ('Fast','Quality') else 1)
    if args.gui: gui();return
    if args.both and (not args.image or not args.port or args.export or args.resolution or args.reference):
        ap.error('--both requires --image/--port and cannot combine with --export/--resolution/--reference')
    if args.show and (not args.both or args.source == 'camera'):
        ap.error('--show requires --both and cannot combine with --source camera')
    if args.preload and (args.both or args.export or not args.image or not args.port):
        ap.error('--preload requires a single --image/--port upload')
    if args.reference_dir and not args.both:
        ap.error('--reference-dir requires --both')
    client=None
    try:
        if args.port:
            client=Client(args.port,args.baud)
            client.force_upload=args.force_upload
            client.window=args.window
            client.baseline_flush=args.baseline_flush
            client.metrics_dir=args.metrics_dir
        status=client.command(HELLO) if client else None
        if status: print(status)
        if args.status and client:
            extended = client.status_extended()
            print(extended if extended is not None else 'Legacy firmware: extended cache status unavailable')
        if args.both:
            client.preload_both(args.image,args.format,args.fit,args.reference_dir)
            if client:
                apply_view_controls(client, args.mode, args.compare)
            if args.show: client.select_source(True)
        elif args.image:
            resolution=args.resolution or (1080 if status and status['resolution'] else 720)
            reference=args.reference or args.image.with_name(args.image.stem+'_fpga_reference.png')
            payload,size=prepare_image(args.image,resolution,args.format,args.fit,reference)
            image_id=content_image_id(payload,size,args.format)
            if args.export:
                export_file(args.export,payload,size,args.format,image_id)
                print(f'Exported {args.export.stat().st_size} binary bytes; send at 115200 8N1, no newline conversion.')
            elif client:
                receipt=client.upload_image(payload,size,args.format,image_id)
            else: ap.error('--image requires --port or --export')
            print(f'Exact FPGA input reference: {reference}')
        if client:
            apply_view_controls(client, args.mode, args.compare)
            if args.image and not args.preload and args.source != 'camera' and 'receipt' in locals():
                client.select_source(True)
                client.wait_displayed(receipt)
                print(f'DISPLAYED image={receipt["image_id"]}')
            elif args.source:
                client.select_source(args.source == 'uart')
        elif not args.export: ap.error('select --gui, --port, or --image with --export')
    finally:
        if client: client.close()


if __name__=='__main__':
    main()
