#!/usr/bin/env python3
"""Enable/disable the cascade link on one board, via the existing UDP client.

Disable on A before using its PC static-image workflow; the remote preview and
PC upload intentionally share the existing image DDR slots in this first stage.
"""
import argparse
import json
from ethernet_image_host import Client

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('state', choices=('on', 'off'))
    parser.add_argument('--board-ip', default='192.168.137.2')
    parser.add_argument('--local-ip', default='0.0.0.0')
    parser.add_argument('--local-port', type=int, default=6010)
    args = parser.parse_args()
    client = Client(args.board_ip, local_ip=args.local_ip, local_port=args.local_port)
    try:
        reply = client.request(12, bytes([args.state == 'on']))
        print(json.dumps({'requested_cascade': args.state, 'board': args.board_ip,
                          'ack_observed': True, 'status': reply}, ensure_ascii=False, indent=2))
    finally:
        client.close()

if __name__ == '__main__':
    main()
