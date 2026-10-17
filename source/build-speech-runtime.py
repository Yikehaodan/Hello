"""Build a relocatable, app-private Python runtime; no system packages modified."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib,json,subprocess,tarfile,zipfile,shutil,os,sys,fcntl
ROOT=Path(__file__).resolve().parent.parent
CACHE=ROOT/'.build-runtime'; CACHE.mkdir(exist_ok=True)
LOCK=(CACHE/'runtime.lock').open('a'); fcntl.flock(LOCK,fcntl.LOCK_EX)
DEST=ROOT/'Knock.app/Contents/Resources/SpeechRuntime'
ARCHIVE='cpython-3.12.15+20261009-aarch64-apple-darwin-install_only_stripped.tar.gz'
PYTHON_SHA='233f8e15255b3e1d1fd47ea5dd5230dfed803f371138e896e54d98c60ae19f6f'

def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(8*1024*1024),b''):h.update(b)
 return h.hexdigest()
def download(url,path,checksum=None):
 if path.exists() and (not checksum or digest(path)==checksum):return
 part=path.with_name(path.name+'.part')
 for attempt in range(3):
  result=subprocess.run(['/usr/bin/curl','-fL','--show-error','--connect-timeout','20',
   '--max-time','900','--continue-at','-','-o',str(part),url])
  if result.returncode==0 and part.exists() and (not checksum or digest(part)==checksum):
   os.replace(part,path);return
  if result.returncode in (22,33) or (result.returncode==0 and checksum):part.unlink(missing_ok=True)
 raise RuntimeError('Download incomplete: '+path.name+'. Run setup again to resume; check GitHub/PyPI connectivity.')
def package(item):
 name,version=item;meta=CACHE/f'{name}-{version}.json'
 download(f'https://pypi.org/pypi/{name}/{version}/json',meta)
 j=json.loads(meta.read_text())
 candidates=[x for x in j['urls'] if x['filename'].endswith('.whl') and 'arm64' in x['filename'] and ('cp312' in x['filename'] or 'py3-none' in x['filename'])]
 # Use macOS wheels only; never execute downloaded build scripts.
 x=next(x for x in candidates if 'macosx' in x['filename'])
 path=CACHE/x['filename'];download(x['url'],path,x['digests']['sha256']);return path
archive=CACHE/ARCHIVE
download('https://github.com/astral-sh/python-build-standalone/releases/download/20261009/'+ARCHIVE,archive,PYTHON_SHA)
if not (DEST/'python/bin/python3').exists():
 DEST.mkdir(parents=True,exist_ok=True)
 with tarfile.open(archive) as tf:
  # Python 3.9 shipped with some command-line tools has no extraction filters.
  if hasattr(tarfile,'data_filter'):tf.extractall(DEST,filter='data')
  else:
   for member in tf.getmembers():
    target=(DEST/member.name).resolve()
    if not target.is_relative_to(DEST.resolve()):raise RuntimeError('Unsafe runtime archive path')
    if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):raise RuntimeError('Unsupported archive entry')
    if member.issym() or member.islnk():
     link=(target.parent/member.linkname if member.issym() else DEST/member.linkname).resolve()
     if not link.is_relative_to(DEST.resolve()):raise RuntimeError('Unsafe runtime archive link')
   tf.extractall(DEST)
packages=[('numpy','2.3.5'),('regex','2026.9.29'),('mlx','0.31.2'),('mlx-metal','0.31.2'),('sherpa-onnx','1.13.8'),('sherpa-onnx-core','1.13.8')]
with ThreadPoolExecutor(max_workers=4) as pool:wheels=list(pool.map(package,packages))
site=DEST/'python/lib/python3.12/site-packages';site.mkdir(parents=True,exist_ok=True)
for wheel in wheels:
 with zipfile.ZipFile(wheel) as z:
  for info in z.infolist():
   target=(site/info.filename).resolve()
   if not target.is_relative_to(site.resolve()):raise RuntimeError('Wheel path escaped runtime')
  z.extractall(site)
qwen=ROOT/'vendor/qwen3-asr-mlx'
shutil.copytree(qwen/'mlx_qwen3_asr',site/'mlx_qwen3_asr',dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
licenses=DEST/'licenses';licenses.mkdir(exist_ok=True)
shutil.copy2(qwen/'LICENSE',licenses/'qwen3-asr-mlx-APACHE-2.0.txt')
(DEST/'runtime-manifest.json').write_text(json.dumps({'python_archive':ARCHIVE,'python_sha256':PYTHON_SHA,'wheels':[{'file':p.name,'sha256':digest(p)} for p in wheels],'qwen_runtime_commit':'41878a11cf338c59e13edc84bf4cb35f4b0f3ff6'},indent=2))
subprocess.run([str(DEST/'python/bin/python3'),'-I','-B','-c','import numpy,sherpa_onnx,mlx.core;from mlx_qwen3_asr import Session;print("Speech runtime ready")'],check=True)
(DEST/'READY').write_text('1\n')
print('Bundled speech runtime:',DEST)
