import importlib.util, unittest
spec=importlib.util.spec_from_file_location('bridge','Integrations/usage_bridge.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
class UsageTests(unittest.TestCase):
    def test_unknown_is_not_zero(self): self.assertEqual(b.normalize([('5h',None)],100)['windows'],[])
    def test_valid_zero(self): self.assertEqual(b.normalize([('5h',{'used_percentage':0,'resets_at':200})],100)['windows'][0]['usedPercent'],0)
    def test_invalid_or_expired(self):
        for percent,reset in [(101,200),(-1,200),(float('nan'),200),(50,99),(True,200),(1790000000,200)]:
            self.assertEqual(b.normalize([('x',{'usedPercent':percent,'resetsAt':reset})],100)['windows'],[])
    def test_both_windows(self):
        r=b.normalize([('5h',{'usedPercent':20,'resetsAt':200}),('week',{'used_percentage':80,'resets_at':300})],100)
        self.assertEqual([w['usedPercent'] for w in r['windows']],[20,80])
    def test_claude_reset_times(self):
        for text in ['2026-09-30T20:00:00Z','2026-09-30T20:00:00+00:00','2026-09-30T20:00:00.123456789+00:00','2026-09-30T20:00:00.5Z']:
            self.assertAlmostEqual(b.parse_time(text),1790798400,delta=1)
        for bad in [None,'',5,'not a date']: self.assertIsNone(b.parse_time(bad))
    def test_claude_local_counts(self):
        import json, os, tempfile
        now=1790800000
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(d+'/proj')
            def row(mid,hours_ago,n): return json.dumps({'timestamp':datetime.utcfromtimestamp(now-hours_ago*3600).isoformat()+'Z',
                'message':{'id':mid,'usage':{'input_tokens':n,'output_tokens':n,'cache_read_input_tokens':999}}})
            with open(d+'/proj/s.jsonl','w') as f:
                f.write('\n'.join([row('a',1,10),row('a',1,10),row('b',6,100),row('c',200,1000),'not json'])+'\n')
            r=b.claude_local(now,d)
        # 'a' counted once (duplicate line), cache reads ignored, 'c' is older than 7 days.
        self.assertEqual(r,{'fiveHourTokens':20,'weekTokens':220})
    def test_gemini_counts(self):
        import json, os, tempfile
        now=1790800000
        def ts(h): return datetime.utcfromtimestamp(now-h*3600).isoformat()+'Z'
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(d+'/abc/chats')
            msg=lambda i,h,inp,cached,out: {'id':i,'timestamp':ts(h),'type':'gemini','tokens':{'input':inp,'cached':cached,'output':out,'thoughts':1,'total':0}}
            with open(d+'/abc/chats/session-1.jsonl','w') as f:
                f.write('\n'.join(json.dumps(r) for r in [{'sessionId':'s'},msg('a',1,100,40,10),msg('a',1,100,40,20),
                                                            {'$set':{'messages':[msg('b',6,50,0,5)]}},msg('c',300,999,0,999)])+'\n')
            with open(d+'/abc/chats/session-2.json','w') as f: json.dump({'messages':[msg('d',2,10,0,0)]},f)
            r=b.gemini(now,d)['local']
        # a: latest record wins (60+20+1); b: 6h ago, week only (56); c: too old; d: legacy .json file (11).
        self.assertEqual(r,{'fiveHourTokens':92,'weekTokens':148})
    def test_month_start(self):
        self.assertEqual(time.strftime('%Y-%m-%d %H:%M',time.gmtime(b.month_start(1790800000))),'2026-09-01 00:00')
import time
from datetime import datetime
unittest.main()
