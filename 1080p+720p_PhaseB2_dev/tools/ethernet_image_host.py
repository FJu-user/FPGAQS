#!/usr/bin/env python3
"""Official NetAssist command bridge and reliable HX1P35 UDP image transport.

The GUI remains the official NetAssistv4325.exe. This script supplies image
conversion, packetization, CRC, ACK and retry; it has no replacement GUI.
"""
from __future__ import annotations
import argparse
import binascii
import json
import secrets
import shlex
import socket
import struct
import time
from pathlib import Path
import uart_image_sender as image

BLOCK = 1024
BOARD_IP = '192.168.137.2'
BOARD_PORT = 6002
HOST_PORT = 6001
OFFICIAL_EXE = Path(__file__).resolve().parent / 'NetAssist' / 'NetAssistv4325.exe'


def encode(command, session=0, sequence=0, payload=b''):
    if len(payload) > BLOCK:
        raise ValueError('Ethernet payload exceeds 1024 bytes')
    head = struct.pack('<BBBBIIH', 1, command, 0, 0, session, sequence, len(payload))
    head += struct.pack('<H', binascii.crc_hqx(head, 0xffff))
    body = head + payload
    return body + struct.pack('<I', binascii.crc32(body))


class Client:
    def __init__(self, board_ip=BOARD_IP, board_port=BOARD_PORT,
                 local_ip='0.0.0.0', local_port=HOST_PORT, timeout=1.0, retries=5):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.socket.bind((local_ip, local_port))
            self.socket.connect((board_ip, board_port))
            self.socket.settimeout(timeout)
        except Exception:
            self.socket.close()
            raise
        self.timeout, self.retries = timeout, retries
        self.session = secrets.randbits(32)
        self.control_sequence = 0
        self.retry_count = 0

    def close(self):
        self.socket.close()

    def request(self, command, payload=b'', *, session=None, sequence=None):
        if session is None:
            session = self.session
        if sequence is None:
            sequence = self.control_sequence
            self.control_sequence += 1
        packet = encode(command, session, sequence, payload)
        for attempt in range(self.retries + 1):
            self.socket.send(packet)
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                self.socket.settimeout(max(0.001, deadline - time.monotonic()))
                try:
                    raw = self.socket.recv(2048)
                except socket.timeout:
                    break
                try:
                    cmd, sid, seq, body, flags = image.decode_packet(raw)
                except ValueError:
                    continue
                if (cmd, sid, seq, flags) != (command | 0x80, session, sequence, 0):
                    continue
                status = image.parse_status(body)
                if status['error']:
                    raise RuntimeError(f"FPGA error {status['error']}: {image.ERRORS.get(status['error'], 'unknown')}")
                return status
            if attempt < self.retries:
                self.retry_count += 1
        raise TimeoutError(f'No valid ACK for command={command}, sequence={sequence}; packet retried unchanged')

    def upload(self, path, resolution=720, mode=0, pixel_format='rgb565', fit='contain', progress=None):
        if not 0 <= mode <= 17:
            raise ValueError('mode must be 0..17')
        data, size = image.prepare_image(path, resolution, pixel_format, fit)
        return self.upload_bytes(data, size, pixel_format, mode, progress)

    def upload_bytes(self, data, size, pixel_format='rgb565', mode=0, progress=None):
        if size not in ((1280, 720), (1920, 1080)):
            raise ValueError('image must be 1280x720 or 1920x1080')
        if pixel_format not in ('rgb565', 'rgb888') or not 0 <= mode <= 17:
            raise ValueError('unsupported format or mode')
        if len(data) != size[0] * size[1] * (2 if pixel_format == 'rgb565' else 3):
            raise ValueError('image byte count mismatch')
        session = secrets.randbits(32)
        image_id = image.content_image_id(data, size, pixel_format)
        self.request(image.BEGIN, image.begin_payload(data, size, pixel_format, image_id), session=session, sequence=0)
        started = time.monotonic()
        last_progress = started
        try:
            chunks = (len(data) + BLOCK - 1) // BLOCK
            for seq in range(chunks):
                end = min(len(data), (seq + 1) * BLOCK)
                status = self.request(image.DATA, data[seq*BLOCK:end], session=session, sequence=seq)
                if status['next_sequence'] != seq + 1 or status['received_bytes'] != end:
                    raise RuntimeError(f'FPGA ACK frontier mismatch at packet {seq}')
                if progress and (time.monotonic() - last_progress >= 0.5 or seq+1 == chunks):
                    progress(f'UPLOAD {end}/{len(data)} bytes ({100*end/len(data):.1f}%)')
                    last_progress = time.monotonic()
            status = self.request(image.END, session=session, sequence=chunks)
            if status['ready_image_id'] != image_id:
                raise RuntimeError('END did not publish the expected image_id')
            self.request(image.MODE, bytes([mode]))
            self.request(image.SOURCE, b'\x01')
            return dict(result='READY', image_id=image_id, width=size[0], height=size[1],
                        format=pixel_format, requested_mode=mode, bytes=len(data),
                        seconds=round(time.monotonic()-started, 3), retries=self.retry_count,
                        evidence='HOST ACK OBSERVED; HDMI/hardware image must be checked separately')
        except Exception:
            try:
                self.request(image.ABORT, session=session, sequence=0)
            except Exception:
                pass
            raise


def execute_command(client, text, progress=None):
    args = [part.strip('"\'') for part in shlex.split(text.strip(), posix=False)]
    if not args:
        raise ValueError('empty command; use HELP')
    command = args[0].upper()
    if command == 'HELP':
        return {'commands': ['UPLOAD "F:/path/image.png" [720|1080] [mode 0..17] [rgb565|rgb888]',
                             'MODE 0..17', 'CAMERA', 'IMAGE', 'COMPARE processed|raw|split', 'STATUS']}
    if command == 'UPLOAD' and 2 <= len(args) <= 5:
        return client.upload(args[1], int(args[2]) if len(args)>2 else 720,
                             int(args[3]) if len(args)>3 else 0,
                             args[4].lower() if len(args)>4 else 'rgb565', progress=progress)
    if command == 'MODE' and len(args) == 2:
        mode = int(args[1])
        if not 0 <= mode <= 17:
            raise ValueError('mode must be 0..17')
        return client.request(image.MODE, bytes([mode]))
    if command in ('CAMERA', 'IMAGE') and len(args) == 1:
        return client.request(image.SOURCE, bytes([command == 'IMAGE']))
    if command == 'COMPARE' and len(args) == 2:
        views = {'processed':0, 'raw':1, 'split':2}
        if args[1].lower() not in views:
            raise ValueError('COMPARE requires processed, raw or split')
        return client.request(image.COMPARE, bytes([views[args[1].lower()]]))
    if command == 'STATUS' and len(args) == 1:
        return client.request(image.HELLO)
    raise ValueError('invalid command; use HELP')


def decode_frontend(data):
    # NetAssist releases/settings differ between UTF-8 and Windows ANSI/GBK.
    # Preserve Chinese image paths without changing the official executable.
    try:
        return data.decode('utf-8').strip(), 'utf-8'
    except UnicodeDecodeError:
        return data.decode('gb18030').strip(), 'gb18030'


def serve(client, port=6000):
    # The official GUI talks to this localhost-only command socket. The image
    # UDP socket uses real Ethernet to the FPGA, independently of the GUI port.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as frontend:
        frontend.bind(('127.0.0.1', port))
        print(f'Official NetAssist: UDP, remote 127.0.0.1:{port}, local port 6003, UTF-8 text', flush=True)
        print(f'GUI executable: {OFFICIAL_EXE}', flush=True)
        print('Commands: HELP, UPLOAD "F:/path/image.png" 720 12 rgb565, MODE 16, CAMERA, IMAGE, STATUS', flush=True)
        while True:
            data, address = frontend.recvfrom(4096)
            encoding = 'utf-8'
            def report(value):
                frontend.sendto((str(value)+'\r\n').encode(encoding, errors='replace'), address)
            try:
                text, encoding = decode_frontend(data)
                report('ACCEPTED '+text)
                result = execute_command(client, text, report)
                report(json.dumps(result, ensure_ascii=False))
            except Exception as exc:
                report('ERROR '+str(exc))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board-ip', default=BOARD_IP)
    parser.add_argument('--board-port', type=int, default=BOARD_PORT)
    parser.add_argument('--local-ip', default='0.0.0.0')
    parser.add_argument('--local-port', type=int, default=HOST_PORT)
    parser.add_argument('--timeout', type=float, default=1.0)
    parser.add_argument('--retries', type=int, default=5)
    parser.add_argument('--bridge', action='store_true', help='Use the official NetAssist GUI as command frontend')
    parser.add_argument('--bridge-port', type=int, default=6000)
    parser.add_argument('--command', help='Optional direct CLI diagnostic command')
    options = parser.parse_args()
    if options.timeout <= 0 or options.retries < 0:
        parser.error('timeout must be positive and retries nonnegative')
    if not options.bridge and not options.command:
        parser.error('choose --bridge or --command')
    client = Client(options.board_ip, options.board_port, options.local_ip,
                    options.local_port, options.timeout, options.retries)
    try:
        if options.bridge:
            serve(client, options.bridge_port)
        else:
            print(json.dumps(execute_command(client, options.command, print), ensure_ascii=False, indent=2))
    finally:
        client.close()


if __name__ == '__main__':
    main()
