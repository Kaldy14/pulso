import unittest,tempfile
from pathlib import Path
import relay
class Response:
    def __init__(self,status): self.status=status;self.reads=0
    def read(self,n): self.reads+=1;return b'ok' if self.reads==1 else b''
class Connection:
    def __init__(self,status=200): self.status=status;self.closed=False;self.calls=[]
    def request(self,*a,**kw): self.calls.append(kw['body'].read())
    def getresponse(self): return Response(self.status)
    def close(self): self.closed=True
class Tests(unittest.TestCase):
    def test_shared_connection_reuses_transport_and_preserves_order(self):
        with tempfile.TemporaryDirectory() as d:
            relay.SPOOL=Path(d);c=Connection()
            for data in [b'first',b'second']:
                p=Path(d)/'page.json';p.write_bytes(data)
                self.assertTrue(relay.forward_one(p,'synthetic',c));self.assertFalse(p.exists())
            self.assertEqual(c.calls,[b'first',b'second']);self.assertFalse(c.closed)
    def test_non_success_keeps_file(self):
        with tempfile.TemporaryDirectory() as d:
            relay.SPOOL=Path(d);p=Path(d)/'page.json';p.write_bytes(b'keep')
            self.assertFalse(relay.forward_one(p,'synthetic',Connection(503)));self.assertEqual(p.read_bytes(),b'keep')
    def test_lost_connection_keeps_file_and_closes_transport(self):
        class Broken(Connection):
            def getresponse(self): raise OSError('test failure')
        with tempfile.TemporaryDirectory() as d:
            relay.SPOOL=Path(d);p=Path(d)/'page.json';p.write_bytes(b'keep');c=Broken()
            self.assertFalse(relay.forward_one(p,'synthetic',c));self.assertTrue(c.closed);self.assertTrue(p.exists())
if __name__=='__main__': unittest.main()
