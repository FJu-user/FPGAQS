#!/usr/bin/env python3
"""Explicit hardware benchmark: force full 720+1080 transfers, never cache hits.

Run --help first. No hardware is accessed merely by importing this module.
"""
import argparse
import json
import time
from pathlib import Path
from uart_image_sender import Client, BAUD_RATES, DEFAULT_METRICS_DIR


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--baud', type=int, choices=BAUD_RATES, default=921600)
    parser.add_argument('--format', choices=('rgb565', 'rgb888'), default='rgb888')
    parser.add_argument('--repeats', type=int, default=10)
    parser.add_argument('--baseline-flush', action='store_true')
    parser.add_argument('--window', type=int, choices=(1,8), default=1)
    parser.add_argument('--output', type=Path, default=DEFAULT_METRICS_DIR)
    args = parser.parse_args()
    if args.repeats < 1 or not args.image.is_file():
        parser.error('positive --repeats and an existing --image are required')
    directory = args.output / f'bench_{time.strftime("%Y%m%d_%H%M%S")}_{time.time_ns()}'
    directory.mkdir(parents=True)
    results = dict(hardware=True, port=args.port, image=str(args.image.resolve()),
                   baud=args.baud, format=args.format, window=args.window,
                   baseline_flush=args.baseline_flush, requested_runs=args.repeats,
                   completed_runs=0, runs=[])
    client = None
    try:
        client = Client(args.port, args.baud)
        client.force_upload = True
        client.window = args.window
        client.baseline_flush = args.baseline_flush
        client.metrics_dir = directory
        for index in range(args.repeats):
            print(f'Run {index+1}/{args.repeats}: forced dual preload', flush=True)
            started = time.monotonic()
            first = len(client.metrics_history)
            run = dict(index=index+1, outcome='running')
            results['runs'].append(run)
            try:
                client.preload_both(args.image, args.format,
                                    reference_dir=directory / 'references')
                run['outcome'] = 'ready'
                results['completed_runs'] += 1
            except Exception as exc:
                run.update(outcome='failed', error=str(exc))
                raise
            finally:
                run['wall_elapsed_s'] = time.monotonic()-started
                run['images'] = client.metrics_history[first:]
                run['transfer_elapsed_s'] = sum(x['elapsed_s'] for x in run['images'])
                (directory / 'benchmark.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    except Exception as exc:
        results['error'] = str(exc)
        raise
    finally:
        if client:
            client.close()
        (directory / 'benchmark.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
        print(f'Benchmark report: {directory / "benchmark.json"}')


if __name__ == '__main__':
    main()
