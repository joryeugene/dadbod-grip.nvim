#!/usr/bin/python3
"""Synthetic protocol/denial model; real OS pipe and signal lifecycle."""
import json, os, re, signal, sys, time
from pathlib import Path
root, mode = Path(sys.argv[1]), sys.argv[2]
root.mkdir(exist_ok=True)
(root/'pid').write_text(str(os.getpid()))
(root/'argv.json').write_text(json.dumps(sys.argv))
(root/'password').write_text(os.environ.get('MYSQL_PWD',''))
if mode == 'hang': signal.signal(signal.SIGTERM, signal.SIG_IGN)
with (root/'stdin').open('w') as capture:
 for line in sys.stdin:
  capture.write(line);capture.flush()
  if 'SHOW FULL COLUMNS' in line and mode == 'metadata-deny':
   sys.stderr.write('ERROR 1044 (42000): synthetic source metadata denied\n');sys.exit(1)
  if 'DERIVED_ORIGINAL_SECRET' in line and mode == 'original-deny':
   sys.stderr.write('ERROR 1142 (42000): synthetic original read denied\n');sys.exit(1)
  match=re.fullmatch(r"SELECT '([a-zA-Z0-9_]+_ROWS)_END';\n",line)
  if match:
   if mode == 'hang':
    (root/'ready').write_text('ready')
    while True:time.sleep(1)
   output='X0' if mode=='malformed' else 'X00FF41'
   if mode=='text':output='TC3A9'
   output+='\n'+('1\nWarning\t1265\tData truncated\n' if mode=='warning' else '0\n')+match[1]+'_END\n'
   data=output.encode()
   for at in range(0,len(data),3):
    os.write(1,data[at:at+3]);time.sleep(.0002)
