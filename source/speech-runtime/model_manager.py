"""Download verified model files and atomically publish a complete installation."""
import argparse,fcntl,hashlib,json,os,signal,subprocess,sys,tarfile,tempfile,time,shutil
from pathlib import Path
from urllib.parse import urlparse
CATALOG=json.loads(Path(__file__).with_name('models.json').read_text())
class InstallError(Exception):pass
class Cancelled(Exception):pass

def emit(**values):print(json.dumps(values,ensure_ascii=False),flush=True)
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(8*1024*1024),b''):h.update(block)
 return h.hexdigest()
def valid(path,file):return path.is_file() and not path.is_symlink() and path.stat().st_size==file['bytes'] and digest(path)==file['sha256']
def validate(directory,spec):
 for file in spec['files']:
  if not valid(directory/file['name'],file):raise InstallError('模型校验失败，请重试下载。')
def safe_name(name):
 if Path(name).name!=name or name in ['.','..']:raise InstallError('模型文件名无效。')
 return name

def download(file,cache,done,total):
 name=safe_name(file.get('name','archive.tar.bz2'));target=cache/name;part=cache/(name+'.part')
 if valid(target,file):
  emit(stage='下载语音模型',progress=min(.85,(done+file['bytes'])/total*.85),bytes=done+file['bytes'],total=total);return target
 if target.exists():target.unlink()
 for attempt in range(3):
  url=file['url']
  endpoint=os.environ.get('KNOCK_HF_ENDPOINT','https://huggingface.co').rstrip('/')
  parsed=urlparse(endpoint)
  if parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
   raise InstallError('模型镜像必须是有效的 HTTPS 地址。')
  if url.startswith('https://huggingface.co/'):url=endpoint+url[len('https://huggingface.co'):]
  if 'github.com/' in url:url+='?knock='+str(time.time_ns())
  args=['/usr/bin/curl','-fL','--silent','--show-error','--connect-timeout','20','--max-time','1800','--speed-limit','1024','--speed-time','45','--continue-at','-','-o',str(part),url]
  log=tempfile.TemporaryFile();child=subprocess.Popen(args,stderr=log)
  try:
   while child.poll() is None:
    count=min(file['bytes'],part.stat().st_size if part.exists() else 0)
    emit(stage='下载语音模型',progress=min(.85,(done+count)/total*.85),bytes=done+count,total=total)
    time.sleep(.25)
   # A connection may close after all bytes arrived; checksum determines validity.
   if valid(part,file):os.replace(part,target);return target
   if child.returncode in (33,22) and part.exists():part.unlink()
   elif part.exists() and part.stat().st_size>=file['bytes']:part.unlink()
   if attempt==2:raise InstallError('下载中断或校验失败（'+str(urlparse(url).hostname)+'）。已保留未完成数据，请检查网络后继续下载。')
  finally:
   if child.poll() is None:
    child.terminate()
    try:child.wait(timeout=1)
    except subprocess.TimeoutExpired:child.kill();child.wait()
   log.close()
 raise InstallError('下载失败，请重试。')

def extract(archive,stage,spec):
 with tarfile.open(archive) as tf:
  for file in spec['files']:
   name=safe_name(file['name']);member=tf.getmember(spec['archive']['prefix']+'/'+name)
   if not member.isfile() or member.size!=file['bytes']:raise InstallError('下载包不完整，请重试。')
   with tf.extractfile(member) as source,(stage/name).open('wb') as dest:shutil.copyfileobj(source,dest,1024*1024)
  for name in ['LICENSE','README.md']:
   try:
    member=tf.getmember(spec['archive']['prefix']+'/'+name)
    if member.isfile() and member.size<65536:
     with tf.extractfile(member) as source,(stage/name).open('wb') as dest:shutil.copyfileobj(source,dest)
   except KeyError:pass

def convert_qwen(source,stage):
 import mlx.core as mx
 from mlx.utils import tree_flatten
 from mlx_qwen3_asr import load_model
 from mlx_qwen3_asr.convert import quantize_model
 from mlx_qwen3_asr.load_models import _model_uses_tied_lm_head
 mx.set_cache_limit(128*1024*1024)
 model,config=load_model(str(source),dtype=mx.float16);mx.clear_cache()
 quantize_model(model,bits=4,encoder_bits=8,group_size=64)
 weights=dict(tree_flatten(model.parameters()))
 if _model_uses_tied_lm_head(config):
  for key in list(weights):
   if key.startswith('lm_head.'):del weights[key]
 mx.save_safetensors(str(stage/'weights.safetensors'),weights)
 for name in ['config.json','tokenizer_config.json','vocab.json','merges.txt','chat_template.json','preprocessor_config.json']:shutil.copy2(source/name,stage/name)
 (stage/'quantization_config.json').write_text(json.dumps({'bits':4,'group_size':64,'audio_tower_bits':8},indent=2))

def install(model_id,root,adopt=None):
 spec=CATALOG['models'][model_id];root.mkdir(parents=True,exist_ok=True)
 lock=(root/'.install.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 dest=root/'Models'/model_id;dest.parent.mkdir(exist_ok=True)
 backup=dest.with_name(dest.name+'.previous')
 if not dest.exists() and backup.exists():os.replace(backup,dest)
 cache=root/'Downloads'/model_id;cache.mkdir(parents=True,exist_ok=True)
 stage=Path(tempfile.mkdtemp(prefix=model_id+'-',dir=dest.parent))
 try:
  required=sum(f['bytes'] for f in spec['files'])
  if not adopt:
   if 'archive' in spec:required+=spec['archive']['bytes']
   elif not spec.get('derive') or not (root/'Models'/spec['derive']/'installed.json').is_file():
    source_spec=CATALOG['models'].get(spec.get('derive'),spec)
    required+=sum(max(0,f['bytes']-min(f['bytes'],(cache/f['name']).stat().st_size if (cache/f['name']).exists() else ((cache/(f['name']+'.part')).stat().st_size if (cache/(f['name']+'.part')).exists() else 0))) for f in source_spec['files'])
  if shutil.disk_usage(root).free<required+128_000_000:raise InstallError('磁盘空间不足，请腾出空间后重试。')
  if adopt:
   for f in spec['files']:shutil.copy2(adopt/safe_name(f['name']),stage/f['name'])
  elif 'archive' in spec:
   archive=download(spec['archive'],cache,0,spec['archive']['bytes']);emit(stage='解压语音模型',progress=.88);extract(archive,stage,spec)
  else:
   source_spec=CATALOG['models'].get(spec.get('derive'),spec)
   source_directory=cache
   reusable=root/'Models'/str(spec.get('derive',''))
   reuse=False
   if spec.get('derive') and (reusable/'installed.json').is_file():
    try:validate(reusable,source_spec);reuse=True;source_directory=reusable
    except InstallError:pass
   if not reuse:
    files=source_spec['files'];total=sum(f['bytes'] for f in files);done=0
    for f in files:
     download(f,cache,done,total);done+=f['bytes']
   if spec.get('derive'):
    emit(stage='正在压缩模型',progress=.88);convert_qwen(source_directory,stage)
   else:
    for f in source_spec['files']:shutil.copy2(cache/f['name'],stage/f['name'])
  emit(stage='校验语音模型',progress=.96);validate(stage,spec)
  (stage/'installed.json').write_text(json.dumps({'id':model_id,'revision':CATALOG['revision'],'files':spec['files']},ensure_ascii=False,indent=2))
  for f in stage.iterdir():os.chmod(f,0o600)
  os.chmod(stage,0o700)
  backup=dest.with_name(dest.name+'.previous')
  if backup.exists():shutil.rmtree(backup)
  if dest.exists():os.replace(dest,backup)
  try:os.replace(stage,dest)
  except BaseException:
   if backup.exists() and not dest.exists():os.replace(backup,dest)
   raise
  shutil.rmtree(backup,ignore_errors=True)
  # Keep partial data on failure/cancel, release completed downloads after publication.
  shutil.rmtree(cache,ignore_errors=True)
  emit(stage='下载完成',progress=1,installed=True)
 finally:
  shutil.rmtree(stage,ignore_errors=True);lock.close()

def interrupted(signum,frame):raise Cancelled()
if __name__=='__main__':
 try:
  try:os.setsid()
  except PermissionError:pass
  signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
  p=argparse.ArgumentParser();p.add_argument('--install',choices=list(CATALOG['models']));p.add_argument('--verify',choices=list(CATALOG['models']));p.add_argument('--list',action='store_true');p.add_argument('--root',type=Path);p.add_argument('--adopt',type=Path);args=p.parse_args()
  if args.list:
   for key,spec in CATALOG['models'].items():emit(id=key,bytes=sum(f['bytes'] for f in spec['files']),download_bytes=spec['archive']['bytes'] if 'archive' in spec else sum(f['bytes'] for f in CATALOG['models'].get(spec.get('derive'),spec)['files']))
   sys.exit(0)
  if not args.root or not (args.install or args.verify):p.error('--root and --install or --verify are required')
  if args.verify:
   validate(args.root/'Models'/args.verify,CATALOG['models'][args.verify]);emit(verified=True,id=args.verify);sys.exit(0)
  emit(stage='准备下载',progress=0,group=os.getpgrp())
  install(args.install,args.root,args.adopt)
 except Cancelled:emit(cancelled=True);sys.exit(2)
 except BlockingIOError:emit(error='另一个窗口正在下载模型，请等待它完成。');sys.exit(1)
 except InstallError as e:emit(error=str(e));sys.exit(1)
 except Exception:emit(error='模型安装失败，可以继续下载重试。');sys.exit(1)
