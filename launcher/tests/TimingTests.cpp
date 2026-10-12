#include "../native/SpeechTimeline.hpp"
#include <iostream>
#include <cstdlib>
int main() {
 int failures=0;
 auto check=[&](bool yes,const char* name){ std::cout<<(yes?"PASS ":"FAIL ")<<name<<"\n";if(!yes)++failures; };
 auto separated=normalizeRanges({{100,300},{250,400},{800,1000}},2000,2000);
 check(separated.size()==2 && separated[0].start==100 && separated[0].end==400 && separated[1].start==800,"overlapping detector windows deduplicate without filling pauses");
 auto bounded=normalizeRanges({{-10,100},{900,1200},{500,500}},1000,2000);
 check(bounded.size()==2 && bounded[0].start==0 && bounded[1].end==1000,"ranges clamp to source and discard zero duration");
 auto split=normalizeRanges({{100,650}},1000,200);
 check(split.size()==3 && split[0].start==100 && split[0].end==300 && split[2].start==500 && split[2].end==650,"long speech splits without accumulating source offsets");
 check(normalizeRanges({},1000,200).empty(),"silence produces no subtitle candidates");
 return failures?1:0;
}
