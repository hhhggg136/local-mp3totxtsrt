// Offline, bounded-window speaker embeddings. No enrollment or network access.
#include "sherpa-onnx/c-api/c-api.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <psapi.h>
#else
#include <sys/resource.h>
#endif

static uint32_t u32(std::istream &s) {
  unsigned char b[4]; if (!s.read(reinterpret_cast<char *>(b),4)) throw std::runtime_error("Truncated WAV");
  return uint32_t(b[0]) | uint32_t(b[1])<<8 | uint32_t(b[2])<<16 | uint32_t(b[3])<<24;
}
int main(int argc, char **argv) {
  try {
    if (argc != 6) throw std::runtime_error("Usage: speaker-embeddings model wav ranges output stats");
    auto began=std::chrono::steady_clock::now();
    std::ifstream wav(argv[2],std::ios::binary), ranges(argv[3]);
    char riff[4],wave[4]; wav.read(riff,4); u32(wav); wav.read(wave,4);
    if (std::string(riff,4)!="RIFF" || std::string(wave,4)!="WAVE") throw std::runtime_error("Expected RIFF WAV");
    uint64_t data=0,bytes=0; bool format=false;
    while(wav && !data) {
      char tag[4]; if(!wav.read(tag,4)) break;
      auto size=u32(wav); auto offset=uint64_t(wav.tellg());
      if(std::string(tag,4)=="fmt ") {
        if(size<16) throw std::runtime_error("Invalid WAV format");
        auto a=u32(wav),rate=u32(wav); u32(wav); auto b=u32(wav);
        format=(a==0x00010001 && rate==16000 && b==0x00100002);
      }
      if(std::string(tag,4)=="data") { data=offset;bytes=size;break; }
      wav.seekg(offset+size+(size&1));
    }
    if(!format || !data || !ranges) throw std::runtime_error("Expected 16 kHz mono PCM16 audio");
    wav.seekg(0,std::ios::end);
    if(uint64_t(wav.tellg())<data+bytes) throw std::runtime_error("Incomplete audio");
    SherpaOnnxSpeakerEmbeddingExtractorConfig config{};
    config.model=argv[1]; config.num_threads=2; config.provider="cpu";
    const auto *ex=SherpaOnnxCreateSpeakerEmbeddingExtractor(&config);
    if(!ex) throw std::runtime_error("Cannot load speaker model");
    const int dim=SherpaOnnxSpeakerEmbeddingExtractorDim(ex);
    if(dim!=192) { SherpaOnnxDestroySpeakerEmbeddingExtractor(ex); throw std::runtime_error("Unexpected embedding dimension"); }
    std::ofstream out(argv[4],std::ios::binary);
    if(!out) throw std::runtime_error("Cannot create result");
    out.write("TTSPK001",8);
    std::string line;int cues=0,windows=0;
    while(std::getline(ranges,line)) {
      if(++cues>10000) throw std::runtime_error("Too many cues");
      std::istringstream row(line); std::string id; int64_t first,last;
      if(!(row>>id>>first>>last) || id.size()!=36 || first<0 || last<=first || last/3>int64_t(bytes/2)+1) throw std::runtime_error("Invalid cue range");
      auto start=first/3, end=std::min(last/3,int64_t(bytes/2));
      const int64_t length=std::min<int64_t>(48000,end-start);
      if(length<12800) continue;
      std::vector<int64_t> starts{start};
      if(end-start>48000) starts.push_back(start+(end-start-length)/2);
      if(end-start>72000) starts.push_back(end-length);
      std::sort(starts.begin(),starts.end()); starts.erase(std::unique(starts.begin(),starts.end()),starts.end());
      for(auto at:starts) {
        std::vector<int16_t> pcm(length); std::vector<float> samples(length);
        wav.seekg(data+uint64_t(at)*2);
        if(!wav.read(reinterpret_cast<char *>(pcm.data()),length*2)) throw std::runtime_error("Audio read failed");
        double power=0;
        for(int64_t i=0;i<length;++i) { samples[i]=float(pcm[i])/32768;power+=samples[i]*samples[i]; }
        if(std::sqrt(power/length)<0.002) continue;
        const auto *stream=SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ex);
        SherpaOnnxOnlineStreamAcceptWaveform(stream,16000,samples.data(),int32_t(length));
        SherpaOnnxOnlineStreamInputFinished(stream);
        if(SherpaOnnxSpeakerEmbeddingExtractorIsReady(ex,stream)) {
          const auto *v=SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ex,stream);
          if(!v) { SherpaOnnxDestroyOnlineStream(stream);throw std::runtime_error("Embedding failed"); }
          bool valid=true;for(int i=0;i<dim;++i) valid=valid&&std::isfinite(v[i]);
          if(valid) { out.write(id.data(),36);out.write(reinterpret_cast<const char *>(v),dim*4);++windows; }
          SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v);
        }
        SherpaOnnxDestroyOnlineStream(stream);
      }
    }
    out.close(); if(!out) throw std::runtime_error("Result write failed");
    SherpaOnnxDestroySpeakerEmbeddingExtractor(ex);
    uint64_t peak_rss=0;
#ifdef _WIN32
    PROCESS_MEMORY_COUNTERS memory{}; memory.cb=sizeof(memory);
    if(GetProcessMemoryInfo(GetCurrentProcess(),&memory,sizeof(memory))) peak_rss=memory.PeakWorkingSetSize;
#else
    struct rusage usage{};getrusage(RUSAGE_SELF,&usage);peak_rss=usage.ru_maxrss;
#endif
    double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count();
    std::ofstream stats(argv[5]);stats<<"{\"peakRSSBytes\":"<<peak_rss<<",\"elapsedSeconds\":"<<elapsed<<",\"cues\":"<<cues<<",\"windows\":"<<windows<<"}\n";
    if(!stats) throw std::runtime_error("Stats write failed");
    return 0;
  } catch(const std::exception &e) { std::cerr<<e.what()<<'\n';return 1; }
}
