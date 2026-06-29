#!/usr/bin/env python3
# Run with CLAUDE_CODE_PROFILE_STARTUP=1, capture raw pty stream, print the
# headless-profiler checkpoint lines (last one before the hang = the slow phase).
import os, pty, time, select, fcntl, termios, struct, re
import pyte
COLS, ROWS = 120, 40
LAUNCHER = (os.environ.get('LAUNCHER') or os.path.join(os.path.dirname(os.path.abspath(__file__)),'claude_185'))
pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER']='1'; os.environ['TERM']='xterm-256color'
    os.environ['CLAUDE_CODE_PROFILE_STARTUP']='1'
    os.environ.pop('TMUX',None); os.environ.pop('STY',None)
    os.execv(LAUNCHER,[LAUNCHER]); os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
screen=pyte.Screen(COLS,ROWS)
try: stream=pyte.ByteStream(screen); feed=stream.feed
except AttributeError: stream=pyte.Stream(screen); feed=lambda d: stream.feed(d.decode('utf-8','replace'))
screen.write_process_input=lambda s: os.write(fd, s.encode('latin1','replace') if isinstance(s,str) else s)
raw=bytearray()
end=time.time()+22
while time.time()<end:
    r,_,_=select.select([fd],[],[],0.2)
    if r:
        try: d=os.read(fd,65536)
        except OSError: break
        if not d: break
        raw+=d; feed(d)
        if b'\x1b[c' in d: os.write(fd,b'\x1b[?1;2c')
        if b'\x1b[>0q' in d: os.write(fd,b'\x1bP>|xterm(370)\x1b\\')
        if b'\x1b]11;?' in d: os.write(fd,b'\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\')
open('/tmp/prof.raw','wb').write(bytes(raw))
# strip ANSI, then print profiler/checkpoint lines
text=re.sub(rb'\x1b\[[0-9;?]*[a-zA-Z]', b'', bytes(raw))
text=re.sub(rb'\x1b[\]P][^\x07\x1b]*(\x07|\x1b\\)?', b'', text)
lines=text.decode('utf-8','replace').splitlines()
hits=[l.strip() for l in lines if 'Checkpoint' in l or 'headlessProfiler' in l or 'Profiler' in l or 'startup' in l.lower()]
print("=== profiler/checkpoint lines (%d) ===" % len(hits))
for h in hits[-40:]: print("  ", h)
try: os.kill(pid,9)
except Exception: pass
