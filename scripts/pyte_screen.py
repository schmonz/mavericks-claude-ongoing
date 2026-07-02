#!/usr/bin/env python3
# Launch, run DUR seconds, print the rendered screen + CPU, exact-PID kill.
import os, pty, time, select, sys, fcntl, termios, struct
import pyte
DUR = float(os.environ.get('DUR', '45'))
COLS, ROWS = 120, 40
pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER']='1'; os.environ['TERM']='xterm-256color'
    os.environ.pop('TMUX',None); os.environ.pop('STY',None)
    L=os.environ['LAUNCHER']; os.execv(L,[L]); os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
screen = pyte.Screen(COLS, ROWS)
try: stream=pyte.ByteStream(screen); feed=stream.feed
except AttributeError: stream=pyte.Stream(screen); feed=lambda d: stream.feed(d.decode('utf-8','replace'))
end=time.time()+DUR
while time.time()<end:
    r,_,_=select.select([fd],[],[],0.2)
    if r:
        try: d=os.read(fd,65536)
        except OSError: break
        if not d: break
        feed(d)
        if b'\x1b[c' in d: os.write(fd,b'\x1b[?1;2c')
cpu=os.popen('ps -o %%cpu= -p %d'%pid).read().strip()
print("=== CPU=%s%% screen after %gs:" % (cpu, DUR))
for line in screen.display:
    if line.strip(): print("|", line.rstrip())
try: os.kill(pid, 9)
except ProcessLookupError: pass
print("=== killed", pid)
