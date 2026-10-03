'use strict';

const DURATION=1.90, OPENING_DURATION=.42, ACCENT_START=.55, COMPRESSION_PEAK=.70, REBOUND_PEAK=.94, ACCENT_END=1.16;
const amplitudes=Object.freeze({subtle:.45,balanced:.75,jelly:1});
const ease=t=>{t=Math.max(0,Math.min(1,t));return t*t*(3-2*t);};
const between=(time,start,end,a,b)=>a+(b-a)*ease((time-start)/(end-start));

// One material accent after opening. The top and centre remain anchored;
// width compensates height, with zero velocity at every segment boundary.
function sample(time,{style='jelly',reduceMotion=false}={}) {
  if(reduceMotion || time<0 || time>=DURATION)return {openingProgress:1,heightOffset:0,widthOffset:0,glow:0,iconLift:0,iconSquash:0,reveal:1};
  let accent=0;
  if(time>=ACCENT_START && time<COMPRESSION_PEAK)accent=between(time,ACCENT_START,COMPRESSION_PEAK,0,1);
  else if(time>=COMPRESSION_PEAK && time<REBOUND_PEAK)accent=between(time,COMPRESSION_PEAK,REBOUND_PEAK,1,-.35);
  else if(time>=REBOUND_PEAK && time<ACCENT_END)accent=between(time,REBOUND_PEAK,ACCENT_END,-.35,0);
  const amplitude=amplitudes[style]??amplitudes.jelly,material=accent*amplitude,lift=Math.max(0,accent);
  return {openingProgress:ease(time/OPENING_DURATION),heightOffset:-3.5*material||0,widthOffset:4*material||0,
    glow:time<=1.10?ease(time/OPENING_DURATION):1-ease((time-1.10)/(DURATION-1.10)),
    iconLift:-5*lift*lift*amplitude||0,iconSquash:material*.055,reveal:ease((time-.44)/.10)};
}
module.exports={sample,DURATION,OPENING_DURATION,ACCENT_START,COMPRESSION_PEAK,REBOUND_PEAK,ACCENT_END,amplitudes};
