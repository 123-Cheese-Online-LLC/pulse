#!/usr/bin/env python3
"""Read account limits only. Never starts a model turn or reads conversation content."""
import json, math, os, pathlib, selectors, subprocess, sys, time, tempfile, urllib.request, urllib.error
from datetime import datetime
ROOT = pathlib.Path.home() / 'Library/Application Support/Pulse'

def normalize(windows, now=None):
    now = time.time() if now is None else now
    valid = []
    for label, raw in windows:
        if not isinstance(raw, dict): continue
        used = raw.get('usedPercent', raw.get('used_percentage'))
        reset = raw.get('resetsAt', raw.get('resets_at'))
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not 0 <= used <= 100: continue
        if not isinstance(reset, (int, float)) or not math.isfinite(reset) or reset <= now: continue
        valid.append({'label':label, 'usedPercent':used, 'resetsAt':reset})
    return {'updatedAt':now, 'windows':valid}

def save(provider, data):
    ROOT.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=ROOT, prefix='usage-')
    try:
        with os.fdopen(fd, 'w') as f: json.dump(data, f)
        os.replace(tmp, ROOT / (provider + '-usage.json'))
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def codex():
    candidates = [
        '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
        '/Applications/Codex.app/Contents/Resources/codex',
        '/opt/homebrew/bin/codex', str(pathlib.Path.home()/'.local/bin/codex')]
    executable = next((p for p in candidates if os.access(p, os.X_OK)), None)
    if not executable: return
    p = subprocess.Popen([executable,'app-server','--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector(); selector.register(p.stdout, selectors.EVENT_READ)
    def send(obj): p.stdin.write((json.dumps(obj)+'\n').encode()); p.stdin.flush()
    try:
        send({'id':0,'method':'initialize','params':{'clientInfo':{'name':'pulse_usage','title':'Pulse','version':'1.2'}}})
        end = time.monotonic()+20; buffer=b''
        while time.monotonic()<end:
            if not selector.select(timeout=1): continue
            chunk=os.read(p.stdout.fileno(),65536)
            if not chunk: break
            buffer+=chunk
            if len(buffer)>1048576: break
            while b'\n' in buffer:
                line,buffer=buffer.split(b'\n',1)
                try: msg=json.loads(line)
                except ValueError: continue
                if '--debug' in sys.argv: print(json.dumps({'id':msg.get('id'),'method':msg.get('method'),'error':msg.get('error')}),file=sys.stderr)
                if msg.get('id')==0:
                    if 'error' in msg: return
                    send({'method':'initialized','params':{}})
                    send({'id':1,'method':'account/rateLimits/read'})
                elif msg.get('id')==1:
                    result=msg.get('result',{})
                    limit=(result.get('rateLimitsByLimitId') or {}).get('codex') or result.get('rateLimits') or {}
                    windows=[]
                    for key in ('primary','secondary'):
                        raw=limit.get(key)
                        if isinstance(raw,dict):
                            mins=raw.get('windowDurationMins')
                            label='Weekly' if mins==10080 else '5 hour' if mins==300 else f'{mins} min'
                            windows.append((label,raw))
                    data=normalize(windows); save('codex',data)
                    print(json.dumps(data)); return
    finally:
        selector.close()
        p.terminate()
        try: p.wait(timeout=2)
        except subprocess.TimeoutExpired: p.kill(); p.wait()

def parse_time(value):
    # Python 3.9 fromisoformat needs +00:00 instead of Z and 6 fractional digits.
    if not isinstance(value,str): return None
    try:
        head,_,zone=value.replace('Z','+00:00').partition('+')
        if '.' in head: head=head.split('.')[0]+'.'+head.split('.')[1][:6].ljust(6,'0')
        return datetime.fromisoformat(head+('+'+zone if zone else '+00:00')).timestamp()
    except ValueError: return None

def claude_api():
    """Exact 5-hour/weekly % (as /usage shows), read-only with Claude Code's saved login.
    The token is only sent to Anthropic, never stored, printed, or refreshed.
    Returns None when the login is missing, expired, or rejected."""
    out=subprocess.run(['/usr/bin/security','find-generic-password','-s','Claude Code-credentials','-w'],
                       capture_output=True,text=True,timeout=10)
    if out.returncode: return None
    oauth=json.loads(out.stdout).get('claudeAiOauth') or {}
    token,expires=oauth.get('accessToken'),oauth.get('expiresAt')
    if not token or (isinstance(expires,(int,float)) and 0<expires/1000<=time.time()): return None
    req=urllib.request.Request('https://api.anthropic.com/api/oauth/usage',headers={
        'Authorization':'Bearer '+token,'anthropic-beta':'oauth-2025-04-20','Accept':'application/json'})
    with urllib.request.urlopen(req,timeout=15) as r: body=json.load(r)
    windows=[]
    for key,label in [('five_hour','5 hour'),('seven_day','Weekly'),('seven_day_opus','Weekly Opus'),('seven_day_sonnet','Weekly Sonnet')]:
        raw=body.get(key)
        if isinstance(raw,dict):
            windows.append((label,{'usedPercent':raw.get('utilization'),'resetsAt':parse_time(raw.get('resets_at'))}))
    return normalize(windows)

def claude_local(now=None, root=None):
    """Tokens Claude Code used in the last 5 hours / 7 days, from its local session logs.
    Works for desktop and Terminal sessions with no login. Only usage numbers are read."""
    now=time.time() if now is None else now
    root=pathlib.Path(root) if root else pathlib.Path.home()/'.claude/projects'
    week_start,seen,five,week=now-7*86400,set(),0,0
    for f in root.rglob('*.jsonl'):
        try:
            if f.stat().st_mtime<week_start: continue  # Skip old sessions without opening them.
            lines=open(f,errors='ignore')
        except OSError: continue
        with lines:
            for line in lines:
                if '"usage"' not in line: continue  # Cheap filter before parsing JSON.
                try: d=json.loads(line)
                except ValueError: continue
                m=d.get('message')
                u=m.get('usage') if isinstance(m,dict) else None
                t=parse_time(d.get('timestamp'))
                key=(m.get('id') if isinstance(m,dict) else None) or d.get('requestId')
                if not isinstance(u,dict) or t is None or t<week_start or key in seen: continue
                seen.add(key)  # One API response can be logged on several lines.
                n=sum(u.get(k) or 0 for k in ('input_tokens','cache_creation_input_tokens','output_tokens') if isinstance(u.get(k),int))
                week+=n
                if t>=now-5*3600: five+=n
    return {'fiveHourTokens':five,'weekTokens':week}

def claude_refresh():
    data=None
    try: data=claude_api()
    except (OSError, ValueError, subprocess.SubprocessError): pass
    if not data or not data['windows']:
        # No exact % available: fall back to local token counts so Claude never shows blank.
        data={'updatedAt':time.time(),'windows':[],'local':claude_local(),
              'note':'Exact % needs a Claude Code login (run claude, then /login)'}
    save('claude',data); print(json.dumps(data))

def claude():
    data=json.load(sys.stdin)
    rate=data.get('rate_limits') or {}
    result=normalize([(label,rate.get(key)) for key,label in [('five_hour','5 hour'),('seven_day','Weekly'),('spend_limit','Spend limit')]])
    save('claude',result)
    parts=[f"{w['label']}: {w['usedPercent']:.0f}% used" for w in result['windows']]
    print('Pulse · '+(' | '.join(parts) if parts else 'usage not reported yet'))

if __name__=='__main__':
    mode=sys.argv[1] if len(sys.argv)>1 else ''
    # 'refresh' polls both providers; one failing must not block the other.
    for job in {'codex':[codex],'claude':[claude],'claude-api':[claude_refresh],'refresh':[codex,claude_refresh]}.get(mode,[]):
        try: job()
        except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
            pass # Preserve the previous timestamp; never present a failure as zero usage.
