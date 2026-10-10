"""Inspect known native640 source patches without changing source or gates.

python3 inspect_native_source_colors.py ARTIFACT_DIRECTORY RUN_ID PR_HEAD_SHA
Actual ffmpeg tagged RGB is compared with known fixture nominal values at the
same interior ROIs/tolerance as the native test. Forced601 is diagnosis only.
"""
from pathlib import Path
from fractions import Fraction
import sys,subprocess,shutil,json,statistics
from PIL import Image,ImageDraw

root=Path(sys.argv[1]).resolve();out=root/'media-validation';out.mkdir(exist_ok=True)
ffprobe,ffmpeg=shutil.which('ffprobe'),shutil.which('ffmpeg')
if not ffprobe or not ffmpeg:raise SystemExit('ffprobe and ffmpeg must be on PATH')
path=root/'video-editor-source.mp4'
probe=json.loads(subprocess.check_output([ffprobe,'-v','error','-select_streams','v:0','-count_frames','-show_streams','-show_frames','-show_format','-of','json',str(path)]))
(out/'source-color-ffprobe.json').write_text(json.dumps(probe,indent=2)+'\n')
stream=probe['streams'][0];pts=[int(f['best_effort_timestamp'])*Fraction(stream['time_base']) for f in probe['frames']]
patches=[('Red',(28,32,44,24),(255,0,0)),('Green',(103,32,44,24),(0,255,0)),('Blue',(178,32,44,24),(0,0,255)),('Neutral',(253,32,24,24),(96,96,96))]
width,height=266,40;frame_size=width*height*3

def crop(mode):
 filt='crop=266:40:20:24,'
 if mode=='forced601':filt+='scale=in_color_matrix=bt601:in_range=tv:out_range=pc,'
 filt+='format=rgb24'
 raw=subprocess.check_output([ffmpeg,'-v','error','-threads','2','-i',str(path),'-vf',filt,'-fps_mode','passthrough','-f','rawvideo','-'])
 assert len(raw)==len(pts)*frame_size
 return [Image.frombytes('RGB',(width,height),raw[start:start+frame_size]) for start in range(0,len(raw),frame_size)]
actual=crop('tagged');diagnostic=crop('forced601')
records=[];contact=Image.new('RGB',(1090,425),'#f4f4f4');draw=ImageDraw.Draw(contact)
for row,seconds in enumerate([.5,2,3.5]):
 normalized=Fraction(str(seconds));index=min(range(len(pts)),key=lambda i:abs(pts[i]-pts[0]-normalized))
 image=actual[index];forced=diagnostic[index]
 for name,(x,y,w,h),nominal in patches:
  box=(x-20,y-24,x-20+w,y-24+h)
  def means(frame):
   region=frame.crop(box);pixels=region.get_flattened_data() if hasattr(region,'get_flattened_data') else region.getdata();pix=list(pixels);return [statistics.fmean(p[c] for p in pix) for c in range(3)]
  rgb,reference601=means(image),means(forced)
  errors=[abs(a-b) for a,b in zip(rgb,nominal)]
  records.append({'patch':name,'requestedNormalizedSeconds':seconds,'actualRawPTSSeconds':float(pts[index]),'actualNormalizedPTSSeconds':float(pts[index]-pts[0]),'decodedFrameIndex':index,'nominalRGB':nominal,'actualTaggedMeanRGB':rgb,'meanAbsoluteRGBChannelDelta':errors,'nominalPassWithinNativeToleranceEight':max(errors)<=8,'forced601DiagnosticMeanRGB':reference601})
 image.save(out/f'source-color-{row+1:02d}-actual.png');forced.save(out/f'source-color-{row+1:02d}-forced601-diagnostic.png')
 y=row*130+28
 draw.text((8,y-20),f'actual MP4 tagged RGB at normalized {seconds:.1f}s; raw PTS {float(pts[index]):.6f}s',fill='black')
 contact.paste(image.resize((532,80),Image.Resampling.NEAREST),(8,y))
 draw.text((550,y-20),'forced601 diagnosis only',fill='black')
 contact.paste(forced.resize((532,80),Image.Resampling.NEAREST),(550,y))
contact.save(out/'source-color-metadata-versus-pixels.png')
validation=json.loads((root/'video-editor-source-color-validation.json').read_text())
report={'sourceCommit':validation['sourceCommit'],'prHeadCommit':sys.argv[3],'githubRunId':sys.argv[2],'method':'Actual ffprobe container tags and every ffmpeg decoded RGB crop from real native synthetic640 source. Solid interior source patches are compared against known nominal input with unchanged native tolerance8. A second explicit601 conversion is diagnostic only; agreement with that assumption does not override actual source tags or acceptance.', 'actualSourceTags':{k:stream.get(k) for k in ['color_range','color_space','color_primaries','color_transfer']},'actualDecodedSourceFrames':len(pts),'sourceRawFirstPTSSeconds':float(pts[0]),'checks':records,'actualTaggedSourceRetainsKnownNominalRGB':all(r['nominalPassWithinNativeToleranceEight'] for r in records),'nativeNominalColorValidationPassed':validation['passed'],'nativeEvidence':validation['evidence'],'limits':['Native preview agreement alone cannot validate nominal input colors or correct source metadata.','The forced601 conversion is an explicit alternative hypothesis, not discovered source metadata.','Interior RGB comparison permits codec quantization; exact byte equality is not required.']}
(out/'native-source-color-validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'sourceCommit':report['sourceCommit'],'actualTags':report['actualSourceTags'],'actualTaggedNominalPass':report['actualTaggedSourceRetainsKnownNominalRGB'],'firstChecks':records[:4]},indent=2))
