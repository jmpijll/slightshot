from pathlib import Path
from PIL import Image, ImageDraw
import numpy as np, json, hashlib

OUT = Path(__file__).resolve().parent
REPORT = json.loads((OUT/'media-validation.json').read_text())
RECTS = {'blur': (1000,760,2050,885), 'pixelate': (1000,968,2650,1093)}

def image(name): return Image.open(OUT/name).convert('RGB')
def crop(img, box, scale=1, margin=8):
    x,y,r,b=box
    return np.array(img.crop((round((x+margin)*scale),round((y+margin)*scale),
                              round((r-margin)*scale),round((b-margin)*scale))),dtype=np.float64)
def edge(a):
    gray=a.mean(axis=2)
    return float((np.abs(np.diff(gray,axis=0)).mean()+np.abs(np.diff(gray,axis=1)).mean())/2)
def difference(a,b): return float(np.abs(a-b).mean())

metrics={}
for quality,scale in [('high',1),('balanced',.5)]:
    metrics[quality]={}
    for effect,rect in RECTS.items():
        times={}
        for frame,label in [('01','before'),('02','during'),('03','after')]:
            actual=image(f'{quality}-{frame}.png')
            source=image(f'source-{frame}.png').resize(actual.size,Image.Resampling.LANCZOS)
            a=crop(actual,rect,scale); s=crop(source,rect,scale)
            times[label]={'meanAbsoluteRGBDifferenceFromSameSourceFrame':difference(a,s),
                'sourceMeanAbsoluteLuminanceGradient':edge(s),
                'exportMeanAbsoluteLuminanceGradient':edge(a),
                'gradientRatioExportToSource':edge(a)/edge(s)}
            if label=='during':
                expected=image('source-rendered-reference.png').resize(actual.size,Image.Resampling.LANCZOS)
                times[label]['meanAbsoluteRGBDifferenceFromSourcePixelRendererReference']=difference(a,crop(expected,rect,scale))
        metrics[quality][effect]=times

fitmetrics={}
fit=928/3840
for quality in ['high','balanced']:
    fitmetrics[quality]={}
    for effect,rect in RECTS.items():
        actual=crop(image(f'{quality}-02-fit.png'),rect,fit,8)
        screenshot=crop(image('screenshot-strength-reference.png'),rect,fit,8)
        original=crop(image('source-fit.png'),rect,fit,8)
        fitmetrics[quality][effect]={
            'meanAbsoluteRGBDifferenceFromScreenshotStrengthReference':difference(actual,screenshot),
            'exportGradientRatioToUnmodifiedSource':edge(actual)/edge(original),
            'screenshotReferenceGradientRatioToUnmodifiedSource':edge(screenshot)/edge(original),
        }

checks={}
for quality,effects in metrics.items():
    for effect,times in effects.items():
        checks[f'{quality}-{effect}-inactive-interval-unmodified-with-codec-tolerance']=all(
            times[t]['meanAbsoluteRGBDifferenceFromSameSourceFrame']<8 for t in ['before','after'])
        checks[f'{quality}-{effect}-active-shows-visible-pixel-change']=times['during']['meanAbsoluteRGBDifferenceFromSameSourceFrame']>5
        checks[f'{quality}-{effect}-active-matches-source-renderer-reference']=times['during']['meanAbsoluteRGBDifferenceFromSourcePixelRendererReference']<8
        checks[f'{quality}-{effect}-active-reduces-fine-edges']=times['during']['gradientRatioExportToSource']<.6
        checks[f'{quality}-{effect}-fit-matches-screenshot-strength']=fitmetrics[quality][effect]['meanAbsoluteRGBDifferenceFromScreenshotStrengthReference']<15

# A focused actual-pixel contact sheet. Labels identify decoded frame, quality and synthetic source.
rows=[]
for effect,rect in RECTS.items():
    for frame,label in [('01','Before 0.25s'),('02','During 1.00s'),('03','After 1.75s')]:
        cells=[]
        for column,name in [('Synthetic source',f'source-{frame}.png'),('High 4K export',f'high-{frame}.png'),('Balanced 1080p export',f'balanced-{frame}.png')]:
            im=image(name); scale=im.width/3840
            box=tuple(round(v*scale) for v in rect)
            patch=im.crop(box).resize((660,80),Image.Resampling.LANCZOS)
            cell=Image.new('RGB',(680,115),'#eeeeee'); cell.paste(patch,(10,30))
            ImageDraw.Draw(cell).text((10,7),f'{effect}: {label} | {column}',fill='#111111')
            cells.append(cell)
        row=Image.new('RGB',(2040,115),'white')
        for col,cell in enumerate(cells):row.paste(cell,(col*680,0))
        rows.append(row)
sheet=Image.new('RGB',(2040,690),'white')
for row,img in enumerate(rows):sheet.paste(img,(0,row*115))
sheet.save(OUT/'privacy-before-during-after.png')

REPORT['privacyValidation']={
 'coordinateSpace': 'Source pixels, top-left origin. Rectangles are from actual native gesture report.',
 'rectangles':RECTS,'intervalSeconds':[.6,1.4],'creationCanvasFitScale':fit,
 'storedRasterScale':1/fit,'fullSourceBlurRadiusPixels':8/fit,'fullSourcePixelBlockSizePixels':round(12/fit),
 'screenshotReference': 'Actual production Renderer.flatten + RasterEffects compiled directly from source commit. Unmodified source at t=1 resized to 928×522 with CGContext high interpolation, then privacy rectangles in displayed canvas coordinates with default screenshot rasterScale=1.',
 'sourcePixelReference': 'Actual production Renderer.flatten on the decoded 3840×2160 source frame at t=1, source-coordinate privacy rectangles and stored rasterScale=4.137931; no vector annotations overlap these privacy rectangles.',
 'nativeResolutionMetrics':metrics,'displayed928x522Metrics':fitmetrics,'checks':checks,
 'allChecksPassed':all(checks.values()),
 'thresholdRationale':'Inactive and source-renderer comparisons allow <8 average RGB levels for H.264/YUV conversion and resampling. Active patches must change >5 RGB levels and reduce fine-edge mean gradient by at least 40%. Screenshot-size reference allows <15 levels because effect crop/block quantization occurs at different resolutions.',
 'limits':['These are image change/strength checks, not a proof of anonymity or an OCR adversary test. Users must review their exported redactions.',
           'Resizing before versus after raster effects and integer pixel-block rounding can shift block boundaries and edge pixels; screenshot strength is comparable, not byte-identical.',
           'Before/during/after video frames validate visible interval behavior at sampled times; automated tests separately validate exact half-open boundaries and fresh source frames.']
}
REPORT['validationPassed']=REPORT['timingPassed'] and all(checks.values())
REPORT['validationFileHashes']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.glob('*.png')}
(OUT/'media-validation.json').write_text(json.dumps(REPORT,indent=2)+'\n')
print(json.dumps({'checks':checks,'native':metrics,'fit':fitmetrics},indent=2))
if not REPORT['validationPassed']:
    raise SystemExit('Privacy pixel validation failed')
