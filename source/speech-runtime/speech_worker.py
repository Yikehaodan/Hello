"""Resident local ASR protocol; only Zipformer uses continuous streaming."""
import argparse,base64,json,os,sys,wave
from pathlib import Path
import numpy as np

def reply(**values):print(json.dumps(values,ensure_ascii=False),flush=True)
def wav(path):
 with wave.open(path) as f:
  if f.getnchannels()!=1 or f.getsampwidth()!=2 or f.getframerate()!=16000 or f.getnframes()>121*16000:raise ValueError('audio')
  return np.frombuffer(f.readframes(f.getnframes()),dtype='<i2').astype(np.float32)/32768

def main():
 p=argparse.ArgumentParser();p.add_argument('--model',required=True,choices=['zipformer','sensevoice','qwen','qwen-lite']);p.add_argument('--root',type=Path,required=True);args=p.parse_args()
 path=args.root/'Models'/args.model
 sys.path.insert(0,str(Path(__file__).resolve().parent))
 from model_manager import CATALOG,validate
 marker=json.loads((path/'installed.json').read_text())
 if marker['id']!=args.model or marker['revision']!=CATALOG['revision']:raise ValueError('model')
 validate(path,CATALOG['models'][args.model])
 if args.model=='zipformer':
  import sherpa_onnx
  recognizer=sherpa_onnx.OnlineRecognizer.from_transducer(tokens=str(path/'tokens.txt'),encoder=str(path/'encoder.int8.onnx'),decoder=str(path/'decoder.onnx'),joiner=str(path/'joiner.int8.onnx'),num_threads=2,provider='cpu',decoding_method='greedy_search',enable_endpoint_detection=False)
 elif args.model=='sensevoice':
  import sherpa_onnx
  recognizer=sherpa_onnx.OfflineRecognizer.from_sense_voice(model=str(path/'model.int8.onnx'),tokens=str(path/'tokens.txt'),num_threads=2,provider='cpu',language='auto',use_itn=True)
 else:
  import mlx.core as mx
  from mlx_qwen3_asr import Session
  mx.set_cache_limit(128*1024*1024)
  recognizer=Session(str(path),dtype=mx.float16);mx.clear_cache()
 reply(ready=True,protocol=1)
 stream=None;stream_id=None;stream_frames=0;has_signal=False;sense_language='auto';prepared=False
 def select_sense_language(language):
  nonlocal recognizer,sense_language
  desired=language if language in ['zh','en','ja','ko','yue'] else 'auto'
  if desired!=sense_language:
   recognizer=sherpa_onnx.OfflineRecognizer.from_sense_voice(model=str(path/'model.int8.onnx'),tokens=str(path/'tokens.txt'),num_threads=2,provider='cpu',language=desired,use_itn=True)
   sense_language=desired
 def flush(s):
  s.accept_waveform(16000,np.zeros(int(.66*16000),np.float32));s.input_finished()
  while recognizer.is_ready(s):recognizer.decode_stream(s)
  return recognizer.get_result(s)
 while True:
  line=sys.stdin.buffer.readline(1_048_577)
  if not line:break
  identifier=''
  try:
   if len(line)>1_048_576 or not line.endswith(b'\n'):raise ValueError('request')
   item=json.loads(line);identifier=item['id'];command=item.get('command','transcribe');language=item.get('language','auto')
   if args.model=='zipformer' and language not in ['zh','auto']:raise ValueError('language')
   if command=='prepare':
    if args.model=='sensevoice':select_sense_language(language)
    if not prepared and args.model in ['qwen','qwen-lite']:
     # Only generated silence is used to compile model operators; no user audio.
     recognizer.transcribe(np.zeros(16000,np.float32),language='Chinese',max_new_tokens=8)
     mx.synchronize();mx.clear_cache()
    prepared=True
    reply(id=identifier,text='')
   elif command=='start':
    if args.model!='zipformer':raise ValueError('stream')
    stream=recognizer.create_stream();stream_id=item['stream'];stream_frames=0;has_signal=False;reply(id=identifier,text='')
   elif command=='feed':
    if stream is None or item['stream']!=stream_id:raise ValueError('session')
    data=base64.b64decode(item['pcm'],validate=True)
    if len(data)%2 or len(data)>128000 or stream_frames+len(data)//2>121*16000:raise ValueError('frames')
    samples=np.frombuffer(data,dtype='<i2').astype(np.float32)/32768;stream_frames+=len(samples);has_signal=has_signal or bool(np.any(np.abs(samples)>.0001))
    stream.accept_waveform(16000,samples)
    while recognizer.is_ready(stream):recognizer.decode_stream(stream)
    reply(id=identifier,text=recognizer.get_result(stream))
   elif command=='finish':
    if stream is None or item['stream']!=stream_id or item['frames']!=stream_frames:raise ValueError('session')
    text=flush(stream) if has_signal else '';stream=None;stream_id=None;reply(id=identifier,text=text)
   elif command=='transcribe':
    samples=wav(item['audio']);dictionary=str(item.get('dictionary',''))[:2000]
    if not bool(np.any(np.abs(samples)>.0001)):text=''
    elif args.model=='zipformer':
     s=recognizer.create_stream();s.accept_waveform(16000,samples);text=flush(s)
    elif args.model=='sensevoice':
     select_sense_language(language)
     s=recognizer.create_stream();s.accept_waveform(16000,samples);recognizer.decode_stream(s);text=s.result.text
    else:
     lang={'zh':'Chinese','en':'English','ja':'Japanese','ko':'Korean','yue':'Cantonese'}.get(language)
     output=recognizer.transcribe(samples,context=dictionary,language=lang)
     if output.truncated:raise ValueError('truncated')
     text=output.text
    reply(id=identifier,text=text)
   else:raise ValueError('command')
  except Exception:reply(id=identifier,error='所选模型识别失败，录音仍可重试。')
if __name__=='__main__':
 try:main()
 except Exception:reply(ready=False,error='语音模型无法载入，请重新下载后重试。');sys.exit(1)
