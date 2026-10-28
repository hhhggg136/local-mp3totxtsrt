"""Separate x64 inference executable. The GUI never imports these large modules."""
import json
import os
from pathlib import Path
import sys


def translate(request):
    import ctranslate2
    import sentencepiece
    package=Path(request['package'])
    metadata=json.loads((package/'metadata.json').read_text(encoding='utf-8'))
    tokenizer=next((p for p in [package/'sentencepiece.model',package/'spm.model'] if p.is_file()),None)
    if tokenizer:
        sp=sentencepiece.SentencePieceProcessor(model_file=str(tokenizer))
        encode=lambda text:sp.encode(text,out_type=str)
        decode=lambda tokens:sp.decode(tokens).replace('▁',' ').replace('_',' ')
    elif (package/'bpe.model').is_file():
        from sacremoses import MosesPunctNormalizer, MosesTokenizer, MosesDetokenizer
        from vendor_argos_bpe import BPE
        normalizer=MosesPunctNormalizer(metadata['from_code']);tokenizer=MosesTokenizer(metadata['from_code'])
        detokenizer=MosesDetokenizer(metadata['to_code'])
        with (package/'bpe.model').open(encoding='utf-8') as stream:bpe=BPE(stream)
        encode=lambda text:bpe.segment_tokens(' '.join(tokenizer.tokenize(normalizer.normalize(text))).strip().split(' '))
        decode=lambda tokens:detokenizer.detokenize(' '.join(tokens).replace('@@ ','').split(' '))
    else:raise ValueError('语言包缺少兼容分词器。')
    model=ctranslate2.Translator(str(package/'model'),device='cpu',compute_type='int8',inter_threads=1,intra_threads=2)
    prefix=metadata.get('target_prefix','');output=[]
    for text in request['texts']:
        tokens=encode(text)
        if not tokens or len(tokens)>480:raise ValueError('有对白过长，请先拆成较短句子再翻译。')
        result=model.translate_batch([tokens],target_prefix=[[prefix]] if prefix else None,
            replace_unknowns=True,beam_size=4,max_batch_size=1,batch_type='examples',
            length_penalty=.2,max_input_length=0,max_decoding_length=768)[0]
        value=decode(result.hypotheses[0]).strip()
        if prefix and value.startswith(prefix):value=value[len(prefix):].strip()
        if not value:raise ValueError('本地模型生成了空译文，请核对语言或重试。')
        output.append(value)
    metrics={}
    if os.name=='nt':
        import ctypes
        import struct
        counters=ctypes.create_string_buffer(80);ctypes.c_uint32.from_buffer(counters).value=80
        ctypes.windll.kernel32.GetCurrentProcess.restype=ctypes.c_void_p
        ctypes.windll.psapi.GetProcessMemoryInfo.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32]
        if ctypes.windll.psapi.GetProcessMemoryInfo(ctypes.windll.kernel32.GetCurrentProcess(),counters,80):
            metrics['peakWorkingSetBytes']=struct.unpack_from('<Q',counters,8)[0]
    return {'texts':output,'engine':'CTranslate2 '+ctranslate2.__version__,'source':metadata['from_code'],'target':metadata['to_code'],**metrics}


def main():
    source,destination=map(Path,sys.argv[1:3])
    try:
        if source.stat().st_size>8_000_000:raise ValueError('单次翻译正文过大，请拆分字幕。')
        result=translate(json.loads(source.read_text(encoding='utf-8')))
    except Exception as exc:
        result={'error':str(exc)}
    part=destination.with_suffix('.part')
    part.write_text(json.dumps(result,ensure_ascii=False),encoding='utf-8');os.replace(part,destination)
    return 1 if 'error' in result else 0


if __name__=='__main__':sys.exit(main())
