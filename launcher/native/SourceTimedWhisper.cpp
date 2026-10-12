#include "whisper.h"
#include "SpeechTimeline.hpp"
#include <fstream>
#include <iostream>
#include <memory>
#include <cmath>
#include <cstring>
#include <string>

// AudioDecoder.swift supplies 16 kHz mono PCM16. Seek and read bounded windows
// rather than loading the entire recording or concatenating speech across pauses.
class Wave {
 std::ifstream file;
 int64_t offset=0;
 static uint32_t u32(const unsigned char* p){return uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24);}
 static uint16_t u16(const unsigned char* p){return uint16_t(p[0])|(uint16_t(p[1])<<8);}
public:
 int64_t frames=0;
 explicit Wave(const std::string& path):file(path,std::ios::binary) {
  unsigned char header[12];
  if(!file.read((char*)header,12)||memcmp(header,"RIFF",4)||memcmp(header+8,"WAVE",4)) throw std::runtime_error("invalid WAV header");
  bool format=false;
  while(file) {
   unsigned char chunk[8];if(!file.read((char*)chunk,8))break;
   uint32_t size=u32(chunk+4);auto begin=file.tellg();
   if(!memcmp(chunk,"fmt ",4)) {
    unsigned char fmt[40]={};
    if(size<16||!file.read((char*)fmt,std::min<uint32_t>(size,40)))throw std::runtime_error("invalid WAV format");
    format=(u16(fmt)==1||(u16(fmt)==0xfffe&&size>=40&&u16(fmt+24)==1))&&u16(fmt+2)==1&&u32(fmt+4)==16000&&u16(fmt+14)==16;
   } else if(!memcmp(chunk,"data",4)) {offset=int64_t(begin);frames=size/2;break;}
   file.seekg(begin+std::streamoff(size+(size%2)));
  }
  if(!format||!offset||!frames)throw std::runtime_error("expected nonempty 16kHz mono PCM16 WAV");
  file.clear();file.seekg(0,std::ios::end);
  if(int64_t(file.tellg())<offset+frames*2)throw std::runtime_error("truncated WAV");
 }
 std::vector<float> read(int64_t start,int64_t end) {
  if(start<0||end>frames||end<=start||end-start>64*16000)throw std::runtime_error("invalid audio window");
  std::vector<int16_t> pcm(size_t(end-start));
  file.clear();file.seekg(offset+start*2);
  if(!file.read((char*)pcm.data(),pcm.size()*2))throw std::runtime_error("failed to read audio window");
  std::vector<float> result(pcm.size());for(size_t i=0;i<pcm.size();++i)result[i]=pcm[i]/32768.0f;
  return result;
 }
};
static std::string jsonString(const std::string& text) {
 std::string result="\"";const char* hex="0123456789abcdef";
 for(unsigned char c:text) {
  if(c=='"'||c=='\\'){result+='\\';result+=char(c);}
  else if(c<32){result+="\\u00";result+=hex[c>>4];result+=hex[c&15];}
  else result+=char(c);
 }
 return result+'"';
}
int main(int argc,char** argv) {
 try {
  if(argc<5||argc>6)throw std::runtime_error("usage: source-timed-whisper model vad-model input.wav output.json [prompt]");
  Wave audio(argv[3]);
  auto vadParams=whisper_vad_default_context_params();vadParams.n_threads=4;vadParams.use_gpu=false;
  std::unique_ptr<whisper_vad_context,decltype(&whisper_vad_free)> vad(whisper_vad_init_from_file_with_params(argv[2],vadParams),whisper_vad_free);
  if(!vad)throw std::runtime_error("failed to load VAD model");
  auto detector=whisper_vad_default_params();
  detector.threshold=0.5f;detector.min_speech_duration_ms=150;detector.min_silence_duration_ms=100;
  detector.speech_pad_ms=0;detector.samples_overlap=0;detector.max_speech_duration_s=15.0f;
  std::vector<SpeechRange> ranges;
  constexpr int64_t rate=16000,block=60*rate,overlap=2*rate;
  for(int64_t core=0;core<audio.frames;core+=block) {
   auto start=std::max<int64_t>(0,core-overlap),end=std::min(audio.frames,core+block+overlap);
   auto samples=audio.read(start,end);
   std::unique_ptr<whisper_vad_segments,decltype(&whisper_vad_free_segments)> segments(whisper_vad_segments_from_samples(vad.get(),detector,samples.data(),int(samples.size())),whisper_vad_free_segments);
   if(!segments)throw std::runtime_error("speech detection failed");
   for(int i=0;i<whisper_vad_segments_n_segments(segments.get());++i) {
    auto from=start+int64_t(std::llround(whisper_vad_segments_get_segment_t0(segments.get(),i)*160.0));
    auto to=start+int64_t(std::llround(whisper_vad_segments_get_segment_t1(segments.get(),i)*160.0));
    ranges.push_back({from,to});
   }
  }
  ranges=normalizeRanges(std::move(ranges),audio.frames,15*rate);
  vad.reset();
  // One model/context per job. Never retain previous-island text as context.
  std::unique_ptr<whisper_context,decltype(&whisper_free)> recognizer(nullptr,whisper_free);
  if(!ranges.empty()) {
   auto config=whisper_context_default_params();
   recognizer.reset(whisper_init_from_file_with_params(argv[1],config));
   if(!recognizer)throw std::runtime_error("failed to load speech model");
  }
  std::ofstream output(argv[4],std::ios::binary|std::ios::trunc);
  if(!output)throw std::runtime_error("cannot create recognition JSON");
  output<<"{\"alignment\":\"source-vad-islands-v1\",\"duration_ms\":"<<audio.frames*1000/rate<<",\"speech_regions\":[";
  for(size_t i=0;i<ranges.size();++i){if(i)output<<',';output<<"{\"from\":"<<ranges[i].start*1000/rate<<",\"to\":"<<ranges[i].end*1000/rate<<'}';}
  output<<"],\"transcription\":[";
  bool first=true;
  for(size_t index=0;index<ranges.size();++index) {
   auto range=ranges[index];
   // Short acoustic padding only assists recognition. Exported times always
   // remain inside the original detected speech island, never inside the padding.
   auto begin=std::max<int64_t>(index?ranges[index-1].end:0,range.start-200*rate/1000);
   auto end=std::min(index+1<ranges.size()?ranges[index+1].start:audio.frames,range.end+200*rate/1000);
   auto samples=audio.read(begin,end);
   auto params=whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
   params.n_threads=4;params.language="zh";params.no_context=true;params.single_segment=true;
   params.print_progress=false;params.print_realtime=false;params.print_timestamps=false;
   params.no_timestamps=true;params.suppress_nst=true;params.vad=false;
   params.initial_prompt=argc==6&&argv[5][0]?argv[5]:nullptr;
   if(whisper_full(recognizer.get(),params,samples.data(),int(samples.size()))!=0)throw std::runtime_error("speech recognition failed");
   std::string text;
   for(int i=0;i<whisper_full_n_segments(recognizer.get());++i)text+=whisper_full_get_segment_text(recognizer.get(),i);
   if(text.find_first_not_of(" \r\n\t")==std::string::npos)continue;
   if(!first)output<<',';first=false;
   output<<"{\"offsets\":{\"from\":"<<range.start*1000/rate<<",\"to\":"<<range.end*1000/rate<<"},\"text\":"<<jsonString(text)<<'}';
   std::cerr<<"source_speech_ms="<<range.start*1000/rate<<"-"<<range.end*1000/rate<<'\n';
  }
  output<<"]}\n";output.flush();if(!output)throw std::runtime_error("recognition JSON write failed");
  return 0;
 } catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
