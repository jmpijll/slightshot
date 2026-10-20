#!/bin/zsh
# Runs the review copy with the injected driver and captures the Settings window
# whenever the driver asks. Hold /tmp/slightshot-native-ui.lock while it runs and
# clear the copy's defaults first: defaults delete com.jmpijll.slightshot.review43
OUT=/tmp/m4review/out
HOMEDIR=/tmp/m4review/home-$(date +%s); mkdir -p $HOMEDIR
SLIGHTSHOT_REVIEW_DIR=$OUT CFFIXED_USER_HOME=$HOMEDIR DYLD_INSERT_LIBRARIES=/tmp/m4probe/review_driver.dylib \
  /tmp/m4review/app/Slightshot.app/Contents/MacOS/Slightshot > $OUT/app.log 2>&1 &
PID=$!
n=1
deadline=$((SECONDS+120))
while kill -0 $PID 2>/dev/null && [ $SECONDS -lt $deadline ]; do
  if [ -f $OUT/step-$n.json ]; then
    sleep 0.4
    name=$(python3 -c "import json;print(json.load(open('$OUT/step-$n.json'))['name'])")
    win=$(python3 -c "import json;print(json.load(open('$OUT/step-$n.json'))['window'])")
    screencapture -x -o -l$win $OUT/$name.png 2>>$OUT/capture.log
    touch $OUT/shot-$n.done
    n=$((n+1))
  fi
  sleep 0.2
done
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
echo "exit after $SECONDS s, shots $((n-1))"
