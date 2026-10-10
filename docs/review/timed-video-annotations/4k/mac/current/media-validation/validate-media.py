from pathlib import Path
import subprocess, json, hashlib, collections
from concurrent.futures import ThreadPoolExecutor

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[6]
OUT.mkdir(exist_ok=True)
VIDEOS = {
    'source': OUT.parent / 'fixture-source.mp4',
    'high': OUT.parent / 'edited-4k-2.mp4',
    'balanced': OUT.parent / 'edited-4k-1.mp4',
}

def inspect(name, path):
    raw = subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-count_frames', '-show_streams', '-show_frames', '-show_entries',
        'stream=width,height,r_frame_rate,avg_frame_rate,time_base,duration,nb_frames,nb_read_frames:frame=best_effort_timestamp,best_effort_timestamp_time,pkt_duration_time',
        '-of', 'json', str(path)])
    probe = json.loads(raw)
    (OUT / (name+'-ffprobe.json')).write_bytes(raw)
    pts = [float(f['best_effort_timestamp_time']) for f in probe['frames']]
    gaps = [round(b-a, 6) for a,b in zip(pts,pts[1:])]
    subprocess.run(['ffmpeg', '-v', 'error', '-threads', '2', '-i', str(path),
        '-vf', 'select=eq(n\\,6)+eq(n\\,24)+eq(n\\,42)', '-fps_mode', 'passthrough', '-frames:v', '3',
        '-y', str(OUT / (name+'-%02d.png'))], check=True)
    return {
        'file': str(path.relative_to(ROOT)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'stream': probe['streams'][0], 'decodedFrameCount': len(pts), 'presentationTimesSeconds': pts,
        'gapHistogramSeconds': dict(collections.Counter(map(str,gaps))),
        'maximumDeviationFromUniform24FPSSeconds': max(abs(g-1/24) for g in gaps),
        'uniform24FPSWithinOneMicrosecond': all(abs(g-1/24)<1e-6 for g in gaps),
        'extractedFrames': [{'frameIndex': i, 'presentationTimeSeconds': pts[i],
                            'file': name+f'-{n:02}.png'} for n,i in enumerate([6,24,42],1)]
    }

with ThreadPoolExecutor(max_workers=3) as pool:
    result = dict(zip(VIDEOS, pool.map(lambda pair: inspect(*pair), VIDEOS.items())))

report = {
    'sourceCommit': '3885ab05d1358839068d9ee9bb05d0c6c688853d',
    'method': 'ffprobe decoded presentation timestamps for every video frame; ffmpeg RGB PNG extraction by exact zero-based frame indices 6, 24, 42 (0.25, 1, 1.75 seconds). Qualities have a maximum cadence and preserve this slower 24 fps source.',
    'tools': {'ffprobe': subprocess.check_output(['ffprobe','-version'],text=True).splitlines()[0],
              'ffmpeg': subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0]},
    'videos': result,
    'timingPassed': all(item['decodedFrameCount']==48 and item['uniform24FPSWithinOneMicrosecond']
                        and float(item['stream']['duration'])==2 for item in result.values()),
    'limits': ['This 2 second synthetic constant-rate recording does not establish arbitrary variable-rate input behavior.',
               'Compressed video pixels include H.264 quantization and YUV-to-RGB conversion; privacy pixel validation is a separate comparison, not exact byte equality.']
}
renderer_sources = ['Sources/Slightshot/Editor/Renderer.swift',
                    'Sources/Slightshot/Editor/Annotation.swift',
                    'Sources/Slightshot/Editor/RasterEffect.swift',
                    'Sources/Slightshot/Support/Geometry.swift']
report['productionRendererSourceHashes'] = {
    name: hashlib.sha256(subprocess.check_output(
        ['git', '-C', str(ROOT), 'show', report['sourceCommit'] + ':' + name])).hexdigest()
    for name in renderer_sources
}
(OUT / 'media-validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({name:{k:item[k] for k in ['decodedFrameCount','gapHistogramSeconds','maximumDeviationFromUniform24FPSSeconds']} for name,item in result.items()},indent=2))
if not report['timingPassed']:
    raise SystemExit('Decoded frame timing validation failed')
