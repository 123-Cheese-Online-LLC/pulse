#!/usr/bin/env python3
"""Read account limits only. Never starts a model turn or reads conversation content."""
import contextlib, io, json, math, os, pathlib, selectors, subprocess, sys, time, tempfile, urllib.request, urllib.error
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

FIVE_H, WEEK = 5*3600, 7*86400
CALIBRATION = ROOT/'claude-calibration.json'

def claude_events(now=None, root=None):
    """(timestamp, tokens) for each Claude Code response in the last 8 days, from its local
    session logs. Desktop and Terminal sessions, no login. Only usage numbers are read."""
    now=time.time() if now is None else now
    root=pathlib.Path(root) if root else pathlib.Path.home()/'.claude/projects'
    since,seen,events=now-8*86400,set(),[]
    for f in root.rglob('*.jsonl'):
        try:
            if f.stat().st_mtime<since: continue  # Skip old sessions without opening them.
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
                if not isinstance(u,dict) or t is None or t<since or key in seen: continue
                seen.add(key)  # One API response can be logged on several lines.
                events.append((t,sum(u.get(k) or 0 for k in ('input_tokens','cache_creation_input_tokens','output_tokens') if isinstance(u.get(k),int))))
    return sorted(events)

def tokens_since(events, start): return sum(n for t,n in events if t>=start)

def five_hour_window(events, now):
    """Claude's 5-hour window opens with the first message after the previous one ended.
    Returns (start, reset) for the window that's open now, or None."""
    start=None
    for t,_ in events:
        if start is None or t>=start+FIVE_H: start=t
    return (start, start+FIVE_H) if start is not None and now<start+FIVE_H else None

def claude_local(now=None, root=None, events=None):
    """Token counts for the open 5-hour window (with its reset time) and the last 7 days."""
    now=time.time() if now is None else now
    events=claude_events(now,root) if events is None else events
    window=five_hour_window(events,now)
    data={'fiveHourTokens':tokens_since(events,now-FIVE_H),'weekTokens':tokens_since(events,now-WEEK)}
    if window: data.update(windowTokens=tokens_since(events,window[0]),windowResetsAt=window[1])
    return data

def calibrate(windows, events, path=CALIBRATION):
    """From an exact reading, learn how many tokens 1% of each window is, for estimates later."""
    try: cal=json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError): cal={}
    for w in windows:
        key,span={'5 hour':('five',FIVE_H),'Weekly':('week',WEEK)}.get(w['label'],(None,0))
        if not key: continue
        if key=='week': cal['weekResetsAt']=w['resetsAt']
        if w['usedPercent']<3: continue  # too little use to measure reliably
        per=tokens_since(events,w['resetsAt']-span)/w['usedPercent']
        if per>0: cal[key]=per if not cal.get(key) else 0.5*cal[key]+0.5*per  # smooth across readings
    pathlib.Path(path).parent.mkdir(parents=True,exist_ok=True)
    pathlib.Path(path).write_text(json.dumps(cal))

def estimate(events, now, path=CALIBRATION):
    """Estimated % for each window, using the learned tokens-per-percent. Empty until calibrated."""
    try: cal=json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError): return []
    out=[]
    window=five_hour_window(events,now)
    if window and cal.get('five'):
        out.append({'label':'5 hour','usedPercent':round(min(100,tokens_since(events,window[0])/cal['five']),1),'resetsAt':window[1],'estimated':True})
    reset=cal.get('weekResetsAt')
    if cal.get('week') and isinstance(reset,(int,float)):
        while reset<=now: reset+=WEEK  # weekly windows repeat on the same schedule
        out.append({'label':'Weekly','usedPercent':round(min(100,tokens_since(events,reset-WEEK)/cal['week']),1),'resetsAt':reset,'estimated':True})
    return out

def claude_refresh():
    now=time.time(); events=claude_events(now); data=None
    try: data=claude_api()
    except (OSError, ValueError, subprocess.SubprocessError): pass
    if data and data['windows']:
        calibrate(data['windows'],events)
    else:
        # No exact % right now: estimate from Claude Code's own logs so Claude never shows blank.
        est=estimate(events,now)
        data={'updatedAt':now,'windows':est,'local':claude_local(now,events=events),
              'note':'Estimated from Claude Code use · Connect for exact %' if est else 'Connect Claude for exact % · until then, tokens used'}
    save('claude',data); print(json.dumps(data))

def claude():
    data=json.load(sys.stdin)
    rate=data.get('rate_limits') or {}
    result=normalize([(label,rate.get(key)) for key,label in [('five_hour','5 hour'),('seven_day','Weekly'),('spend_limit','Spend limit')]])
    save('claude',result)
    parts=[f"{w['label']}: {w['usedPercent']:.0f}% used" for w in result['windows']]
    print('Pulse · '+(' | '.join(parts) if parts else 'usage not reported yet'))

def clear(provider):
    # A provider that isn't set up shouldn't leave an old tile behind.
    try: (ROOT/(provider+'-usage.json')).unlink()
    except FileNotFoundError: pass

def keychain(service):
    """Admin API key that Pulse saved in the Keychain (Pulse → Add)."""
    out=subprocess.run(['/usr/bin/security','find-generic-password','-s',service,'-w'],capture_output=True,text=True,timeout=10)
    return out.stdout.strip() if out.returncode==0 and out.stdout.strip() else None

def month_start(now):
    t=time.gmtime(now); return int(time.mktime((t.tm_year,t.tm_mon,1,0,0,0,0,0,0))-time.timezone)

def spend_record(usd):
    return {'updatedAt':time.time(),'windows':[],'spend':{'usd':round(usd,2),'label':'This month'}}

def get_json(url,headers):
    with urllib.request.urlopen(urllib.request.Request(url,headers=headers),timeout=20) as r: return json.load(r)

def openai_api():
    """Month-to-date spend from OpenAI's Costs API (admin key, amount.value is USD)."""
    key=keychain('Pulse: openai-admin-key')
    if not key: return clear('openai-api')
    body=get_json(f'https://api.openai.com/v1/organization/costs?start_time={month_start(time.time())}&limit=31',
                  {'Authorization':'Bearer '+key})
    usd=sum(float((r.get('amount') or {}).get('value') or 0) for b in body.get('data',[]) for r in b.get('results',[]))
    save('openai-api',spend_record(usd))

def anthropic_api():
    """Month-to-date spend from Anthropic's Cost API (admin key, amounts are cents as decimal strings)."""
    key=keychain('Pulse: anthropic-admin-key')
    if not key: return clear('anthropic-api')
    start=time.strftime('%Y-%m-%dT00:00:00Z',time.gmtime(month_start(time.time())))
    body=get_json(f'https://api.anthropic.com/v1/organizations/cost_report?starting_at={start}&limit=31',
                  {'x-api-key':key,'anthropic-version':'2023-06-01','User-Agent':'Pulse (https://github.com/123-Cheese-Online-LLC/pulse)'})
    cents=sum(float(r.get('amount') or 0) for b in body.get('data',[]) for r in b.get('results',[]))
    save('anthropic-api',spend_record(cents/100))

def copilot():
    """Monthly chat/completions/premium quotas via the GitHub CLI's own login (unofficial endpoint)."""
    gh=next((p for p in ['/opt/homebrew/bin/gh','/usr/local/bin/gh'] if os.access(p,os.X_OK)),None)
    if not gh: return clear('copilot')
    out=subprocess.run([gh,'api','/copilot_internal/user'],capture_output=True,text=True,timeout=20)
    if out.returncode: return clear('copilot')
    d=json.loads(out.stdout); reset=parse_time(d.get('quota_reset_date_utc')) or parse_time((d.get('quota_reset_date') or '')+'T00:00:00Z')
    windows=[]
    for key,label in [('premium_interactions','Premium'),('chat','Chat'),('completions','Completions')]:
        q=(d.get('quota_snapshots') or {}).get(key) or {}
        if q.get('unlimited') or not q.get('entitlement'): continue  # Skip quotas this plan doesn't have.
        windows.append((label,{'usedPercent':100-float(q.get('percent_remaining',100)),'resetsAt':reset}))
    # Every GitHub account gets Copilot Free; only show it once it has actually been used.
    if not any(w[1]['usedPercent']>0 for w in windows):
        clear('copilot'); return 'not used yet'  # status shows why there's no tile
    save('copilot',normalize(windows))

def gemini(now=None, root=None):
    """Gemini CLI tokens in the last 5 hours / 7 days from its local session files (no login)."""
    now,real=(time.time() if now is None else now),root is None
    root=pathlib.Path.home()/'.gemini/tmp' if real else pathlib.Path(root)
    if not root.is_dir(): return clear('gemini') if real else None
    week_start,by_id=now-7*86400,{}
    def take(m):
        if isinstance(m,dict) and isinstance(m.get('tokens'),dict) and m.get('id'): by_id[m['id']]=m  # Later records win.
    for f in list(root.glob('*/chats/*.json'))+list(root.glob('*/chats/*.jsonl')):
        try:
            if f.stat().st_mtime<week_start: continue
            text=f.read_text(errors='ignore')
        except OSError: continue
        if f.suffix=='.json':
            try: [take(m) for m in json.loads(text).get('messages',[])]
            except (ValueError,AttributeError): pass
            continue
        for line in text.splitlines():
            try: r=json.loads(line)
            except ValueError: continue
            if not isinstance(r,dict): continue
            take(r); [take(m) for m in ((r.get('$set') or {}).get('messages') or r.get('messages') or [])]
    five=week=0
    for m in by_id.values():
        t,k=parse_time(m.get('timestamp')),m['tokens']
        if t is None or t<week_start: continue
        # Same convention as Claude: fresh input + output + thinking; cached input excluded.
        n=max(0,(k.get('input') or 0)-(k.get('cached') or 0))+(k.get('output') or 0)+(k.get('thoughts') or 0)
        week+=n; five+=n if t>=now-5*3600 else 0
    data={'updatedAt':time.time(),'windows':[],'local':{'fiveHourTokens':five,'weekTokens':week}}
    if real: save('gemini',data)
    return data

PROVIDERS={'codex':codex,'claude':claude_refresh,'gemini':gemini,'copilot':copilot,'openai-api':openai_api,'anthropic-api':anthropic_api}

def status(show_all=False):
    """Self-test: run every provider and say what each one found. Prints no secrets.
    Tools that aren't set up are hidden unless show_all (status -a)."""
    for name,job in PROVIDERS.items():
        reason=None
        try:
            with contextlib.redirect_stdout(io.StringIO()): reason=job()
            err=None
        except Exception as e: err=type(e).__name__+(f' {e.code}' if hasattr(e,'code') else '')
        try: d=json.loads((ROOT/(name+'-usage.json')).read_text())
        except (OSError,ValueError): d=None
        if err: line='error · '+err
        elif not d:
            if not show_all: continue
            line=reason if isinstance(reason,str) else 'not set up'
        elif d.get('windows'): line=', '.join(f"{w['label']} {'~' if w.get('estimated') else ''}{w['usedPercent']:.0f}%" for w in d['windows'])+(' (estimated)' if d['windows'][0].get('estimated') else '')
        elif d.get('spend'): line=f"${d['spend']['usd']:.2f} this month"
        elif d.get('local') and d['local'].get('windowResetsAt'): line=f"{d['local']['windowTokens']:,} tokens this 5h window, resets {time.strftime('%-I:%M %p',time.localtime(d['local']['windowResetsAt']))} · {d['local']['weekTokens']:,} this week"
        elif d.get('local'): line=f"no open 5h window · {d['local']['weekTokens']:,} tokens this week"
        else: line='no reading'
        print(f'{name:14} {line}')

if __name__=='__main__':
    mode=sys.argv[1] if len(sys.argv)>1 else ''
    if mode=='status': status('-a' in sys.argv or '--all' in sys.argv); sys.exit()
    # 'refresh' polls every provider; one failing must not block the others.
    jobs={'claude':[claude],'claude-api':[claude_refresh],'refresh':list(PROVIDERS.values())}.get(mode) or ([PROVIDERS[mode]] if mode in PROVIDERS else [])
    for job in jobs:
        try: job()
        except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
            pass # Preserve the previous reading; never present a failure as zero usage.
