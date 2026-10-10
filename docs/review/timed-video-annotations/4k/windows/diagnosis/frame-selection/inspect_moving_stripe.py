"""Read-only motion-identity diagnosis, separate from acceptance validators.

python3 inspect_moving_stripe.py ARTIFACT_DIRECTORY [ARTIFACT_DIRECTORY ...]
Uses PATH ffprobe/ffmpeg. Keeps every actual decoded frame (no fps conversion).
An affine blue fit removes a fixed decoder color offset for temporal correlation;
quantized plateaus mean this is evidence of delay, not exact frame identity.
"""
from pathlib import Path
from fractions import Fraction
from bisect import bisect_right
import subprocess, shutil, sys, json, statistics, math

ffprobe, ffmpeg = shutil.which('ffprobe'), shutil.which('ffmpeg')
if not ffprobe or not ffmpeg:
    raise SystemExit('ffprobe and ffmpeg must be on PATH')

def decode(root, name, assume_709=False):
    path = root / ('video-editor-4k-' + name + '.mp4')
    probe = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_streams', '-show_frames', '-of', 'json', str(path)]))
    stream = probe['streams'][0]
    pts = [int(f['best_effort_timestamp']) * Fraction(stream['time_base']) for f in probe['frames']]
    scale = Fraction(stream['width'], 3840)
    width, height, x, y = [int(v * scale) for v in (64, 32, 180, 12)]
    filt = f'crop={width}:{height}:{x}:{y},'
    if assume_709:
        filt += 'scale=in_color_matrix=bt709:in_range=tv:out_range=pc,'
    filt += 'format=rgb24'
    raw = subprocess.check_output([ffmpeg, '-v', 'error', '-threads', '2', '-i', str(path), '-vf', filt, '-fps_mode', 'passthrough', '-f', 'rawvideo', '-'])
    size = width * height * 3
    rgb = [[statistics.fmean(raw[i+c:i+size:3]) for c in range(3)] for i in range(0, len(raw), size)]
    assert len(pts) == len(rgb)
    return pts, rgb, stream

def fit(pairs):
    if len(pairs) < 3:
        return None
    meanx = statistics.fmean(a for a,b in pairs); meany = statistics.fmean(b for a,b in pairs)
    denom = sum((a-meanx)**2 for a,b in pairs)
    if denom == 0:
        return None
    slope = sum((a-meanx)*(b-meany) for a,b in pairs)/denom
    intercept = meany-slope*meanx
    residual = [b-slope*a-intercept for a,b in pairs]
    return {'samples':len(pairs),'slope':slope,'intercept':intercept,'rootMeanSquaredBlueResidual':math.sqrt(statistics.fmean(v*v for v in residual)), 'maximumAbsoluteBlueResidual':max(map(abs,residual))}

for arg in sys.argv[1:]:
    root = Path(arg).resolve(); output=root/'media-validation';output.mkdir(exist_ok=True)
    source_pts, source_rgb, stream = decode(root, 'source')
    assumed_pts, assumed_rgb, _ = decode(root, 'source', True)
    assert source_pts == assumed_pts
    def records(pts, rgb):
        return [{'decodedIndex':i,'actualPTSSeconds':float(t),'exactPTSSeconds':str(t),'meanRGB':rgb[i]} for i,t in enumerate(pts)]
    sr = records(source_pts, source_rgb)
    result = {'method':'Decode each actual frame to a tiny untouched top-stripe RGB crop using fps_mode passthrough. Compare temporal features independently of container frame counts. Blue affine fit is a diagnostic for fixed color offset, not exact RGB equality or a new acceptance gate.',
        'cropSourceCoordinates':[180,12,64,32],
        'sourceInitialPTSSeconds':float(source_pts[0]),
        'sourceSchedulingQuantizationToleranceSeconds':1e-7,
        'sourceColorTags':{k:stream.get(k) for k in ['color_range','color_space','color_primaries','color_transfer']},
        'source':{'actualFrames':len(sr),'firstFive':sr[:5],'lastFive':sr[-5:],'allFrames':sr, 'assumedBT709LimitedRGB':assumed_rgb},
        'outputs':{},
        'limits':['Source lacks explicit color tags in older recorder artifacts. Default FFmpeg RGB conversion can differ from native MF conversion; separate source BT.709-limited conversion is explicitly an assumption, not discovered metadata.',
            'Blue changes by about one channel value per source frame and has genuine codec plateaus. A best correlation shift cannot prove the identity of every individual frame, particularly first/last plateaus.',
            'Raw-PTS source scheduling and normalized source-origin scheduling are compared as explicit alternatives; only code/lifecycle semantics determine the intended policy.']}
    for name in ['high','balanced','step']:
        if not (root/('video-editor-4k-'+name+'.mp4')).exists():continue
        pts, rgb, _ = decode(root,name)
        shifts={}
        if len(rgb)==len(source_rgb):
            for shift in range(-3,4):
                pairs=[(source_rgb[i+shift][2],rgb[i][2]) for i in range(2,len(rgb)-2) if 0<=i+shift<len(source_rgb)]
                shifts[str(shift)]=fit(pairs)
        models={}
        for label, origin in [('rawSourcePTS',Fraction(0)), ('normalizedSourceOrigin',source_pts[0])]:
            indices=[max(0,bisect_right(source_pts,t+origin+Fraction(1,10000000))-1) for t in pts]
            pairs=[(source_rgb[index][2],actual[2]) for index,actual in zip(indices,rgb)]
            models[label]={'sourceIndices':indices,'blueAffineFit':fit(pairs),
                'assumedBT709MeanRGBDifference':[statistics.fmean(abs(actual[c]-assumed_rgb[index][c]) for index,actual in zip(indices,rgb)) for c in range(3)]}
        rec=records(pts,rgb)
        result['outputs'][name]={'actualFrames':len(rec),'firstFive':rec[:5],'lastFive':rec[-5:],'allFrames':rec,'sameCadenceIntegerShiftBlueAffineFits':shifts,'sourceSchedulingModels':models,
            'bestSameCadenceShift':min(shifts,key=lambda s:shifts[s]['rootMeanSquaredBlueResidual']) if shifts else None}
    independent=output/'media-validation.json'
    if independent.exists():
        info=json.loads(independent.read_text())
        for key in ['sourceCommit','prHeadCommit','githubRunId']: result[key]=info.get(key)
    native=root/'video-editor-4k-validation.json'
    if native.exists():
        info=json.loads(native.read_text());result['sourceCommit']=info.get('sourceCommit');result['nativeAcceptanceFailures']=info.get('acceptanceFailures')
    (output/'moving-stripe-identity-diagnostic.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'artifact':str(root),'sourceFirstPTS':result['sourceInitialPTSSeconds'],'outputs':{k:{'actualFrames':v['actualFrames'],'bestShift':v['bestSameCadenceShift'],'rawRMSE':v['sourceSchedulingModels']['rawSourcePTS']['blueAffineFit']['rootMeanSquaredBlueResidual'],'normalizedRMSE':v['sourceSchedulingModels']['normalizedSourceOrigin']['blueAffineFit']['rootMeanSquaredBlueResidual']} for k,v in result['outputs'].items()}},indent=2))
