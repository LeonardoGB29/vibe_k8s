#!/usr/bin/env python3
"""Ensayos medidos del laboratorio VIBE. Evidencias locales; restaura fallos inducidos."""
import argparse
import concurrent.futures
import csv
import json
import math
import os
import pathlib
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave
from datetime import datetime, timezone

NS = 'vibe'
OUT = None
BASE = ''

def command(*args, timeout=30):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[-2000:])
    return result.stdout

def k(*args):
    return command('kubectl', '-n', NS, *args)

def kj(*args):
    return json.loads(k(*args, '-o', 'json'))

def snapshot(name):
    data = {'time': datetime.now(timezone.utc).isoformat()}
    for resource in ('nodes', 'pods', 'deployments', 'statefulsets', 'hpa', 'scaledobject', 'events'):
        try:
            data[resource] = kj('get', resource)
        except Exception as exc:
            data[resource] = {'error': str(exc)}
    (OUT / (name + '.json')).write_text(json.dumps(data, indent=2))

def request(path, timeout=3):
    started = time.monotonic()
    try:
        req = urllib.request.Request(BASE + path, headers={'Cache-Control': 'no-cache'})
        with urllib.request.urlopen(req, timeout=timeout) as res:
            body = res.read()
            code = res.status
            pod = res.headers.get('X-Served-By', '')
    except urllib.error.HTTPError as exc:
        code, body, pod = exc.code, b'', ''
    except Exception:
        code, body, pod = 0, b'', ''
    return code, body, pod, (time.monotonic() - started) * 1000

class Monitor:
    def __init__(self, paths):
        self.paths = paths
        self.rows = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.is_set():
            for path in self.paths:
                code, _, pod, ms = request(path)
                self.rows.append({'utc': datetime.now(timezone.utc).isoformat(), 'path': path,
                                  'status': code, 'latency_ms': round(ms, 3), 'pod': pod})
            self.stop.wait(.25)

    def __enter__(self):
        self.thread.start()
        time.sleep(3)
        return self

    def __exit__(self, *args):
        time.sleep(5)
        self.stop.set()
        self.thread.join(15)
        with (OUT / 'requests.csv').open('w') as f:
            writer = csv.DictWriter(f, fieldnames=['utc', 'path', 'status', 'latency_ms', 'pod'])
            writer.writeheader()
            writer.writerows(self.rows)

    def summary(self):
        result = {}
        for path in self.paths:
            rows = [r for r in self.rows if r['path'] == path]
            latencies = sorted(r['latency_ms'] for r in rows)
            failures = sum(not 200 <= r['status'] < 300 for r in rows)
            result[path] = {'requests': len(rows), 'errors': failures,
                            'error_percent': round(100 * failures / max(1, len(rows)), 3),
                            'p95_ms': latencies[math.ceil(.95 * len(latencies)) - 1] if latencies else None,
                            'served_by': sorted({r['pod'] for r in rows if r['pod']})}
        return result

def ready(pod):
    return not pod['metadata'].get('deletionTimestamp') and any(
        c['type'] == 'Ready' and c['status'] == 'True' for c in pod.get('status', {}).get('conditions', []))

def wait_until(predicate, seconds=180):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(1)
    raise RuntimeError('El ensayo excedió su plazo de recuperación')

def pod_test():
    before = kj('get', 'pods', '-l', 'app=catalog-api')['items']
    running = [p for p in before if ready(p)]
    if len(running) < 2:
        raise RuntimeError('Se requieren al menos dos pods de catálogo Ready')
    old_uids = {p['metadata']['uid'] for p in before}
    victim = running[0]['metadata']['name']
    with Monitor(['/api/tracks?limit=1']) as monitor:
        start = time.monotonic()
        k('delete', 'pod', victim, '--wait=false')
        def recovered():
            current = kj('get', 'pods', '-l', 'app=catalog-api')['items']
            return (sum(ready(p) for p in current) >= len(running)
                    and any(ready(p) and p['metadata']['uid'] not in old_uids for p in current)
                    and not any(p['metadata']['name'] == victim for p in current))
        wait_until(recovered)
        duration = round(time.monotonic() - start, 3)
    return {'deleted_pod': victim, 'recovery_seconds': duration, 'http': monitor.summary()}

def hpa_test():
    stop = threading.Event()
    rows = []
    lock = threading.Lock()
    def load():
        while not stop.is_set():
            code, _, _, ms = request('/api/tracks?limit=50')
            with lock:
                rows.append((code, ms))
            stop.wait(.02)
    series = []
    try:
        for concurrency in (4, 12, 24):
            with concurrent.futures.ThreadPoolExecutor(concurrency) as pool:
                tasks = [pool.submit(load) for _ in range(concurrency)]
                for _ in range(6):
                    time.sleep(10)
                    hpa = kj('get', 'hpa', 'catalog-api-hpa')
                    deploy = kj('get', 'deployment', 'catalog-api')
                    point = {'utc': datetime.now(timezone.utc).isoformat(), 'concurrency': concurrency,
                             'replicas': deploy['spec']['replicas'], 'ready': deploy['status'].get('readyReplicas', 0),
                             'cpu': hpa['status'].get('currentMetrics'), 'desired': hpa['status'].get('desiredReplicas')}
                    series.append(point)
                    print(json.dumps(point), flush=True)
                stop.set()
                for task in tasks:
                    task.result()
            stop.clear()
    finally:
        stop.set()
        (OUT / 'scaling.json').write_text(json.dumps(series, indent=2))
        with (OUT / 'load-requests.csv').open('w') as f:
            writer = csv.writer(f)
            writer.writerow(['status', 'latency_ms'])
            writer.writerows(rows)
    latencies = sorted(ms for _, ms in rows)
    errors = sum(not 200 <= code < 300 for code, _ in rows)
    peak = max(p['replicas'] for p in series)
    return {'peak_replicas': peak, 'scaled': peak > 2, 'requests': len(rows), 'errors': errors,
            'error_percent': round(100 * errors / max(1, len(rows)), 3),
            'p95_ms': round(latencies[math.ceil(.95 * len(latencies)) - 1], 3) if rows else None}

def db_test():
    sts = kj('get', 'statefulset', 'postgres')
    original = sts['spec']['replicas']
    if original != 1:
        raise RuntimeError('PostgreSQL debe estar con una réplica antes del ensayo')
    code, body, _, _ = request('/api/tracks?status=ready&limit=1')
    tracks = json.loads(body) if code == 200 else []
    if not tracks:
        raise RuntimeError('Se requiere un audio listo para probar streaming real')
    track = tracks[0]['id']
    code, body, _, _ = request('/stream/' + track + '/master.m3u8')
    variants = [line for line in body.decode().splitlines() if line and not line.startswith('#')]
    if code != 200 or not variants:
        raise RuntimeError('No se pudo obtener el master HLS')
    variant_path = '/stream/' + track + '/' + variants[0]
    code, body, _, _ = request(variant_path)
    segments = [line for line in body.decode().splitlines() if line and not line.startswith('#')]
    if code != 200 or not segments:
        raise RuntimeError('No se pudo obtener la variante HLS')
    segment_path = variant_path.rsplit('/', 1)[0] + '/' + segments[0]
    try:
        with Monitor(['/api/tracks?limit=1', segment_path]) as monitor:
            k('scale', 'statefulset/postgres', '--replicas=0')
            wait_until(lambda: not kj('get', 'pods', '-l', 'app=postgres')['items'])
            snapshot('database-down')
            time.sleep(20)
            start = time.monotonic()
            k('scale', 'statefulset/postgres', '--replicas=1')
            wait_until(lambda: kj('get', 'statefulset', 'postgres')['status'].get('readyReplicas') == 1)
            wait_until(lambda: request('/api/tracks?limit=1')[0] == 200)
            duration = round(time.monotonic() - start, 3)
    finally:
        k('scale', 'statefulset/postgres', '--replicas=' + str(original))
    return {'track_id': track, 'restore_seconds': duration, 'http': monitor.summary()}

def keda_test():
    queue = int(k('exec', 'deployment/redis', '--', 'redis-cli', 'LLEN', 'transcode').strip())
    if queue:
        raise RuntimeError('La cola debe estar vacía antes de generar los trabajos de prueba')
    ids, uploads, series = [], [], []
    stamp = datetime.now(timezone.utc).strftime('%H%M%S')
    with tempfile.TemporaryDirectory(prefix='vibe-keda-') as temp:
        audio = pathlib.Path(temp) / 'synthetic.wav'
        sample = b''.join(struct.pack('<h', int(5000 * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(16000))
        with wave.open(str(audio), 'wb') as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            for _ in range(480):
                wav.writeframesraw(sample)
        def upload(i):
            start = time.monotonic()
            body = command('curl', '-fsS', '--max-time', '120', '-F', 'file=@' + str(audio),
                           '-F', f'title=Demo KEDA {stamp} {i:02}', '-F', 'artist=Prueba universitaria',
                           BASE + '/api/upload', timeout=125)
            item = json.loads(body)
            return {'id': item['id'], 'latency_ms': round((time.monotonic() - start) * 1000, 3)}
        start = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            futures = [pool.submit(upload, i) for i in range(1, 13)]
            deadline = time.monotonic() + 600
            done = False
            while time.monotonic() < deadline:
                workers = kj('get', 'deployment', 'worker')
                length = int(k('exec', 'deployment/redis', '--', 'redis-cli', 'LLEN', 'transcode').strip())
                point = {'utc': datetime.now(timezone.utc).isoformat(), 'queue': length,
                         'workers': workers['spec']['replicas'], 'ready_workers': workers['status'].get('readyReplicas', 0)}
                series.append(point)
                print(json.dumps(point), flush=True)
                if all(f.done() for f in futures):
                    if not uploads:
                        uploads = [f.result() for f in futures]
                        ids = [item['id'] for item in uploads]
                    code, body, _, _ = request('/api/tracks?limit=500')
                    tracks = json.loads(body) if code == 200 else []
                    states = {t['id']: t['status'] for t in tracks if t['id'] in ids}
                    if len(states) == len(ids) and all(s in ('ready', 'failed') for s in states.values()):
                        done = True
                        break
                time.sleep(3)
        (OUT / 'scaling.json').write_text(json.dumps(series, indent=2))
        (OUT / 'uploads.json').write_text(json.dumps(uploads, indent=2))
        elapsed = round(time.monotonic() - start, 3)
        if not done:
            raise RuntimeError('No terminaron todos los trabajos en diez minutos; no se borraron los audios de prueba')
        failures = {track: status for track, status in states.items() if status != 'ready'}
        # Solo eliminar audios que este ensayo creó y cuya conversión ya terminó.
        for track in ids:
            command('curl', '-fsS', '-X', 'DELETE', BASE + '/api/tracks/' + track)
    latencies = sorted(item['latency_ms'] for item in uploads)
    return {'uploads': len(uploads), 'failed_conversions': failures,
            'peak_queue': max(p['queue'] for p in series), 'peak_workers': max(p['workers'] for p in series),
            'completion_seconds': elapsed, 'upload_p95_ms': latencies[math.ceil(.95 * len(latencies)) - 1],
            'test_tracks_deleted': ids}

def rolling_test():
    deployment = kj('get', 'deployment', 'frontend')
    original = deployment['spec']['template']['spec']['containers'][0]['image']
    version = datetime.now(timezone.utc).strftime('demo-%Y%m%d%H%M%S')
    image = 'vibe-frontend:' + version
    source = pathlib.Path.home() / 'vibe_k8s/vibe/aws/distribute-ssm.sh'
    os.environ['IMAGE_BUCKET'] = 'vibe-audio-raw-413718548840'
    os.environ['AWS_DEFAULT_REGION'] = 'us-east-1'
    with tempfile.TemporaryDirectory(prefix='vibe-release-') as temp:
        folder = pathlib.Path(temp)
        (folder / 'version.json').write_text(json.dumps({'version': version}))
        (folder / 'Dockerfile').write_text('FROM vibe-frontend:dev\nCOPY version.json /usr/share/nginx/html/demo-version.json\n')
        print('Construyendo una imagen distinta con un marcador de versión', flush=True)
        command('docker', 'build', '-t', image, temp, timeout=180)
        archive = folder / 'frontend.tar'
        command('docker', 'save', image, '-o', str(archive), timeout=120)
        command('sudo', 'k3s', 'ctr', 'images', 'import', str(archive), timeout=120)
        print('Distribuyendo la versión de prueba a los tres agentes', flush=True)
        command('bash', str(source), str(archive), timeout=1200)
    try:
        with Monitor(['/healthz']) as monitor:
            start = time.monotonic()
            k('set', 'image', 'deployment/frontend', 'frontend=' + image)
            command('kubectl', '-n', NS, 'rollout', 'status', 'deployment/frontend', '--timeout=180s', timeout=185)
            elapsed = round(time.monotonic() - start, 3)
            code, body, _, _ = request('/demo-version.json')
            if code != 200 or json.loads(body).get('version') != version:
                raise RuntimeError('La nueva versión no se verificó mediante HTTP')
            snapshot('new-version')
    finally:
        k('set', 'image', 'deployment/frontend', 'frontend=' + original)
        command('kubectl', '-n', NS, 'rollout', 'status', 'deployment/frontend', '--timeout=180s', timeout=185)
    return {'old_image': original, 'tested_image': image, 'rollout_seconds': elapsed,
            'restored_original_image': True, 'http': monitor.summary()}

def node_test():
    node = 'k3s-agent-3'
    info = kj('get', 'node', node)
    if any('control-plane' in name for name in info['metadata'].get('labels', {})):
        raise RuntimeError('No se detiene el nodo de control')
    occupants = json.loads(command('kubectl', 'get', 'pods', '-A', '--field-selector', 'spec.nodeName=' + node, '-o', 'json'))['items']
    if any(any('persistentVolumeClaim' in v for v in p['spec'].get('volumes', [])) for p in occupants):
        raise RuntimeError('El agente elegido aloja PVC locales; se cancela la caída para conservar el almacenamiento')
    ip = next(a['address'] for a in info['status']['addresses'] if a['type'] == 'InternalIP')
    result = json.loads(command('aws', 'ec2', 'describe-instances', '--region', 'us-east-1',
                               '--filters', 'Name=private-ip-address,Values=' + ip, 'Name=instance-state-name,Values=running'))
    instances = [i for reservation in result['Reservations'] for i in reservation['Instances']]
    if len(instances) != 1 or not any(t['Key'] == 'Name' and t['Value'] == 'vibe-' + node for t in instances[0].get('Tags', [])):
        raise RuntimeError('No se pudo identificar de forma inequívoca la EC2 del agente de VIBE')
    instance = instances[0]['InstanceId']
    series = []
    original_names = {p['metadata']['name'] for p in kj('get', 'pods')['items']}
    old_names = {p['metadata']['name'] for p in occupants if p['metadata']['namespace'] == NS}
    affected_apps = {p['metadata'].get('labels', {}).get('app') for p in occupants if p['metadata']['namespace'] == NS}
    desired = {d['metadata']['name']: d['spec']['replicas'] for d in kj('get', 'deployments')['items']
               if d['metadata']['name'] in affected_apps}
    def is_ready():
        return any(c['type'] == 'Ready' and c['status'] == 'True' for c in kj('get', 'node', node)['status']['conditions'])
    paths = ['/api/tracks?limit=1', '/healthz']
    code, body, _, _ = request('/api/tracks?status=ready&limit=1')
    tracks = json.loads(body) if code == 200 else []
    if tracks:
        paths.append('/stream/' + tracks[0]['id'] + '/master.m3u8')
    with Monitor(paths) as monitor:
        start = time.monotonic()
        try:
            print('Deteniendo únicamente ' + node + ' durante siete minutos', flush=True)
            command('aws', 'ec2', 'stop-instances', '--region', 'us-east-1', '--instance-ids', instance)
            wait_until(lambda: not is_ready(), 120)
            detected = round(time.monotonic() - start, 3)
            snapshot('node-down')
            while time.monotonic() - start < 420:
                pods = kj('get', 'pods')['items']
                old_remaining = sorted(p['metadata']['name'] for p in pods if p['metadata']['name'] in old_names)
                new_ready = sorted(p['metadata']['name'] for p in pods if ready(p)
                                   and p['metadata']['name'] not in original_names and p['spec'].get('nodeName') != node)
                available = {app: sum(ready(p) and p['metadata'].get('labels', {}).get('app') == app for p in pods)
                             for app in desired}
                point = {'utc': datetime.now(timezone.utc).isoformat(), 'seconds_since_stop': round(time.monotonic() - start, 1),
                         'old_pods_remaining': old_remaining, 'new_ready_pods_on_other_nodes': new_ready,
                         'available_by_app': available, 'all_affected_apps_available': all(available[a] >= count for a, count in desired.items()),
                         'ready_pods': sum(ready(p) for p in pods)}
                series.append(point)
                print(json.dumps(point), flush=True)
                time.sleep(15)
            snapshot('before-node-restart')
        finally:
            print('Restaurando la EC2 del agente', flush=True)
            restarted = time.monotonic()
            command('aws', 'ec2', 'start-instances', '--region', 'us-east-1', '--instance-ids', instance)
            wait_until(is_ready, 300)
            restore = round(time.monotonic() - restarted, 3)
            (OUT / 'node-timeline.json').write_text(json.dumps(series, indent=2))
    return {'node': node, 'instance_id': instance, 'not_ready_seconds': detected,
            'restart_to_ready_seconds': restore, 'old_pods': sorted(old_names),
            'all_old_pods_removed_before_restart': bool(series) and not series[-1]['old_pods_remaining'],
            'first_replacement_ready_seconds': next((p['seconds_since_stop'] for p in series if p['new_ready_pods_on_other_nodes']), None),
            'full_workloads_recovered_seconds': next((p['seconds_since_stop'] for p in series if p['all_affected_apps_available']), None),
            'http': monitor.summary()}

def main():
    global BASE, OUT
    parser = argparse.ArgumentParser()
    parser.add_argument('test', choices=['pod', 'hpa', 'keda', 'rolling', 'db', 'node'])
    parser.add_argument('--base', required=True)
    args = parser.parse_args()
    BASE = args.base.rstrip('/')
    OUT = pathlib.Path.home() / 'vibe-evidence' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + args.test)
    OUT.mkdir(parents=True)
    snapshot('before')
    try:
        result = {'pod': pod_test, 'hpa': hpa_test, 'keda': keda_test, 'rolling': rolling_test, 'db': db_test, 'node': node_test}[args.test]()
        result.update({'test': args.test, 'base_url': BASE, 'evidence_dir': str(OUT)})
        (OUT / 'summary.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result, indent=2), flush=True)
    finally:
        snapshot('after')

if __name__ == '__main__':
    main()
