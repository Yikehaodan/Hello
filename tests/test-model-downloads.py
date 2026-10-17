"""Real HTTP downloads: interrupted range resume, corruption, cancellation and publication."""
import hashlib,http.server,importlib.util,json,os,signal,subprocess,tempfile,threading,time
from pathlib import Path
source=Path(__file__).resolve().parents[1]/'source/speech-runtime/model_manager.py'
spec=importlib.util.spec_from_file_location('manager',source);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
payload=bytes(range(256))*256;requests=[];interrupted=False
class HTTP(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  global interrupted
  offset=int(self.headers.get('Range','bytes=0-').split('=')[1].split('-')[0]);requests.append((self.path,offset))
  data=payload[offset:] if self.path!='/bad' else b'x'*len(payload[offset:])
  self.send_response(206 if offset else 200);self.send_header('Content-Length',str(len(data)))
  if offset:self.send_header('Content-Range',f'bytes {offset}-{len(payload)-1}/{len(payload)}')
  self.end_headers()
  try:
   if self.path=='/resume' and not interrupted:
    interrupted=True;self.wfile.write(data[:10000]);self.wfile.flush();self.close_connection=True
   elif self.path=='/slow':
    for i in range(0,len(data),1024):self.wfile.write(data[i:i+1024]);self.wfile.flush();time.sleep(.08)
   else:self.wfile.write(data)
  except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),HTTP);threading.Thread(target=server.serve_forever,daemon=True).start();url=f'http://127.0.0.1:{server.server_port}'
def entry(endpoint):return {'engine':'sensevoice','files':[{'name':'model.onnx','bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest(),'url':url+endpoint}]}
with tempfile.TemporaryDirectory(prefix='lightvoice-download-test-') as tmp:
 root=Path(tmp);m.CATALOG={'revision':1,'models':{'sensevoice':entry('/resume')}}
 m.install('sensevoice',root/'resume');dest=root/'resume/Models/sensevoice';assert (dest/'model.onnx').read_bytes()==payload and (dest/'installed.json').is_file()
 assert any(path=='/resume' and n==10000 for path,n in requests),'Range resume not used'
 # Offline adoption validates content and never needs another request.
 count=len(requests);m.install('sensevoice',root/'adopt',adopt=dest)
 assert len(requests)==count and (root/'adopt/Models/sensevoice/model.onnx').read_bytes()==payload
 # A failure when publishing a replacement restores the prior complete model.
 previous_replace=m.os.replace
 def fail_publish(source,target):
  if Path(target)==dest and Path(source).parent==dest.parent and not str(source).endswith('.previous'):
   raise OSError('simulated replacement failure')
  return previous_replace(source,target)
 m.os.replace=fail_publish
 try:
  try:m.install('sensevoice',root/'resume',adopt=root/'adopt/Models/sensevoice');raise AssertionError('Expected publish failure')
  except OSError:pass
 finally:m.os.replace=previous_replace
 assert (dest/'model.onnx').read_bytes()==payload and (dest/'installed.json').is_file()

 m.CATALOG['models']['sensevoice']=entry('/bad')
 try:m.install('sensevoice',root/'corrupt');raise AssertionError('Corrupt model published')
 except m.InstallError:pass
 assert not (root/'corrupt/Models/sensevoice/installed.json').exists()
 # Cancellation uses the actual CLI in its own process group and preserves partial bytes.
 fixture=root/'cli';fixture.mkdir();(fixture/'model_manager.py').write_text(source.read_text())
 (fixture/'models.json').write_text(json.dumps({'revision':1,'models':{'sensevoice':entry('/slow')}}))
 proc=subprocess.Popen([os.sys.executable,str(fixture/'model_manager.py'),'--install','sensevoice','--root',str(root/'cancel')],stdout=subprocess.PIPE,text=True)
 first=json.loads(proc.stdout.readline());assert first['group']==proc.pid
 partial=root/'cancel/Downloads/sensevoice/model.onnx.part'
 deadline=time.monotonic()+5
 while not partial.exists() or partial.stat().st_size<1024:
  assert time.monotonic()<deadline;time.sleep(.05)
 os.killpg(proc.pid,signal.SIGTERM);output=proc.communicate(timeout=5)[0];assert proc.returncode==2 and partial.stat().st_size>0
 assert not (root/'cancel/Models/sensevoice/installed.json').exists()
 m.CATALOG['models']['sensevoice']=entry('/slow');m.install('sensevoice',root/'cancel')
 assert (root/'cancel/Models/sensevoice/model.onnx').read_bytes()==payload
 print('PASS: interrupted downloads resume with HTTP Range; corrupted and canceled models never publish; cancellation keeps partial data and retry completes')
server.shutdown()
