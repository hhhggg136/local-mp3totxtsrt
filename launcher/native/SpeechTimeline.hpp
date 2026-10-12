#pragma once
#include <vector>
#include <cstdint>
#include <algorithm>
#include <stdexcept>
struct SpeechRange { int64_t start,end; };
inline std::vector<SpeechRange> normalizeRanges(std::vector<SpeechRange> input,int64_t total,int64_t maxLength) {
 if(total<0 || maxLength<=0) throw std::invalid_argument("invalid source duration");
 std::sort(input.begin(),input.end(),[](auto a,auto b){return a.start<b.start;});
 std::vector<SpeechRange> merged,result;
 for(auto range:input) {
  range.start=std::max<int64_t>(0,range.start);range.end=std::min(total,range.end);
  if(range.end<=range.start) continue;
  if(!merged.empty() && range.start<=merged.back().end) merged.back().end=std::max(merged.back().end,range.end);
  else merged.push_back(range);
 }
 for(auto range:merged) for(auto start=range.start;start<range.end;start+=maxLength) result.push_back({start,std::min(start+maxLength,range.end)});
 return result;
}
