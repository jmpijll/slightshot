#!/usr/bin/env python3
"""Read-only actual MP4 frame/timeline inspection. Requires ffprobe on PATH."""
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

base = Path(sys.argv[1]).resolve()
source = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else base / 'fixture-source.mp4'
out = base / 'media-validation'
out.mkdir(exist_ok=True)
probe = shutil.which('ffprobe')
if not probe:
    raise RuntimeError('ffprobe unavailable; actual decoded count not established')
provenance = json.loads((base / 'published-binary-provenance.json').read_text())
reports = {}
physical_pts = {}
for name, path, dims in [('source', source, (3840, 2160)), ('high', base / 'edited-4k-2.mp4', (3840, 2160)), ('balanced', base / 'edited-4k-1.mp4', (1920, 1080))]:
    data = json.loads(subprocess.check_output([probe, '-v', 'error', '-select_streams', 'v:0', '-count_frames', '-show_streams', '-show_format', '-show_frames', '-of', 'json', str(path)]))
    (out / (name + '-ffprobe.json')).write_text(json.dumps(data, indent=2) + '\n')
    stream = data['streams'][0]
    frames = data['frames']
    timebase = Fraction(stream['time_base'])
    ticks = [int(frame.get('best_effort_timestamp', frame.get('pts'))) for frame in frames]
    pts = [tick * timebase for tick in ticks]
    physical_pts[name] = pts
    durations = [int(frame.get('duration', frame.get('pkt_duration', 0))) * timebase for frame in frames]
    gaps = [pts[i + 1] - pts[i] for i in range(len(pts) - 1)]
    count = int(stream['nb_read_frames'])
    duration = Fraction(stream['duration'])
    checks = {
        'actualDecodedFrames48': count == 48 and len(frames) == 48,
        'actualDimensionsMatch': (stream['width'], stream['height']) == dims,
        'actualDuration2Seconds': abs(duration - 2) <= Fraction(1, 1_000_000),
        'actualFirstPTS0': pts[0] == 0,
        'actualAllPresentationGaps24FPS': all(gap == Fraction(1, 24) for gap in gaps),
        'actualLastPresentation47Over24': pts[-1] == Fraction(47, 24),
        'actualLastSampleCovers2Seconds': abs(pts[-1] + durations[-1] - 2) <= Fraction(1, 1_000_000)
    }
    reports[name] = {
        'file': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'codec': stream['codec_name'], 'profile': stream.get('profile'), 'level': stream.get('level'),
        'actualWidth': stream['width'], 'actualHeight': stream['height'], 'actualDecodedFrames': count,
        'actualDurationSeconds': float(duration), 'actualFirstPresentationSeconds': float(pts[0]),
        'actualLastPresentationSeconds': float(pts[-1]), 'actualLastDurationSeconds': float(durations[-1]),
        'actualNominalFPS': stream['r_frame_rate'], 'actualAverageFPS': stream['avg_frame_rate'],
        'actualVideoBitrateBitsPerSecond': stream.get('bit_rate'),
        'actualPresentationTicks': ticks, 'timebase': stream['time_base'],
        'checks': checks, 'allChecksPass': all(checks.values())
    }
identical_times = physical_pts['source'] == physical_pts['high'] == physical_pts['balanced']
identical_ticks = (reports['source']['timebase'] == reports['high']['timebase'] == reports['balanced']['timebase'] and reports['source']['actualPresentationTicks'] == reports['high']['actualPresentationTicks'] == reports['balanced']['actualPresentationTicks'])
result = {
    'releaseVersion': provenance['releaseVersion'], 'releaseBuild': provenance['releaseBuild'],
    'releaseSourceCommit': provenance['expectedReleaseSourceCommit'],
    'method': 'Independent ffprobe full decode, count_frames, raw frame PTS/durations and stream metadata of the actual published signed Mac app fixture outputs. No submitted-frame counters used. Exact Fraction comparison; decoded duration/coverage permits 1 microsecond decimal representation error.',
    'reports': reports, 'all48SourceOutputPresentationTicksIdentical': identical_ticks,
    'all48SourceOutputPhysicalPresentationTimesIdentical': identical_times,
    'allChecksPass': identical_times and all(item['allChecksPass'] for item in reports.values()),
    'limits': 'Counts, dimensions, timeline and decoded coverage only. No independent repeated privacy pixel or color analysis for this separate published-binary run. Native fixture interaction/export/cancellation checks are reported separately.'
}
(out / 'published-mac-media-validation.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'allChecksPass': result['allChecksPass'], 'actualDecodedFrames': {name: value['actualDecodedFrames'] for name, value in reports.items()}}, indent=2))
raise SystemExit(0 if result['allChecksPass'] else 1)
