import json, pathlib, shutil
home=pathlib.Path.home()
settings=home/'.claude/settings.json'
data=json.loads(settings.read_text()) if settings.exists() else {}
command="/usr/bin/python3 '"+str(home/'Applications/Pulse.app/Contents/Resources/usage_bridge.py')+"' claude"
existing=data.get('statusLine')
if existing and existing.get('command')!=command:
    raise SystemExit('Existing Claude status line changed; preserved without replacement.')
backup=settings.with_name('settings.json.pulse-backup')
if settings.exists() and not backup.exists(): shutil.copy2(settings,backup)
data['statusLine']={'type':'command','command':command}
settings.parent.mkdir(parents=True,exist_ok=True)
settings.write_text(json.dumps(data,indent=2)+'\n')
block='''
<!-- BEGIN PULSE USAGE ADVISORY -->
Before long or resource-heavy work, read `~/Library/Application Support/Pulse/agent-status.json` if available. Ignore machine advice older than 15 seconds; unknown account usage is not zero. `conserve`: keep work concise and avoid optional parallel tasks. `pause`: checkpoint and ask before further expensive optional work. Never terminate apps automatically. These are advisory thresholds, not a substitute for the user's instructions.
<!-- END PULSE USAGE ADVISORY -->
'''
for path in [home/'.codex/AGENTS.md',home/'.claude/CLAUDE.md']:
    old=path.read_text() if path.exists() else ''
    if '<!-- BEGIN PULSE USAGE ADVISORY -->' not in old:
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(old.rstrip()+'\n'+block)
print('Claude usage callback and Codex/Claude advisory instructions installed; existing settings preserved.')
