'use strict';
(function(root){

// Analytic damped spring: preserves velocity on retargeting and does not depend
// on the display refresh rate. Coordinates remain centred on the same axis.
class Spring {
  constructor(value = 0, damping = 1, frequency = 20) {
    this.value = value; this.velocity = 0; this.target = value;
    this.damping = damping; this.frequency = frequency;
  }
  step(dt) {
    const w = this.frequency, z = this.damping, y = this.value - this.target;
    if(z>=1) {
      const b=this.velocity+w*y,decay=Math.exp(-w*dt);
      this.value=this.target+(y+b*dt)*decay;
      this.velocity=(this.velocity-w*b*dt)*decay;
    } else {
      const wd=w*Math.sqrt(1-z*z),b=(this.velocity+z*w*y)/wd;
      const decay=Math.exp(-z*w*dt),s=Math.sin(wd*dt),c=Math.cos(wd*dt);
      this.value=this.target+decay*(y*c+b*s);
      this.velocity=decay*((-y*wd*s+b*wd*c)-z*w*(y*c+b*s));
    }
    if (Math.abs(this.value - this.target) < 0.0005 && Math.abs(this.velocity) < 0.005) {
      this.value = this.target; this.velocity = 0;
    }
    return this.value;
  }
}

// A fixed transparent native canvas contains the evolving black surface and
// its halo. Only a display/work-area change moves or resizes the native window.
function layout(workArea, progress = 0, accent = {}) {
  const canvasWidth=Math.max(80,Math.min(508,workArea.width-16));
  const maximum=Math.max(32,canvasWidth-48),neck=Math.min(280,maximum);
  const p=Math.max(0,Math.min(1,progress)),band=36;
  const surfaceWidth=Math.max(neck,Math.min(canvasWidth-40,neck+(maximum-neck)*p+(accent.widthOffset||0)));
  const body=Math.max(0,164*p+(accent.heightOffset||0));
  return {x:Math.round(workArea.x+workArea.width/2-canvasWidth/2),y:workArea.y,
    width:canvasWidth,height:Math.min(234,workArea.height),surfaceX:(canvasWidth-surfaceWidth)/2,
    surfaceWidth,surfaceHeight:band+body,neck,band,body,progress:p,...accent};
}

// The same contour defines SVG drawing and hit testing, including shoulders
// and rounded bottom corners. Transparent padding never receives input.
function contour(frame) {
  const w=frame.surfaceWidth??frame.width,h=frame.surfaceHeight??frame.height,
    x=frame.surfaceX??0,n=frame.neck,b=frame.band,left=x+(w-n)/2,right=x+(w+n)/2;
  const body=Math.max(0,h-b),shoulder=Math.min(15,body/2),radius=Math.min(28,body/2),r=Math.min(13,b/2),flare=Math.min(6,(w-n)/2),control=Math.min(15,(w-n)/2);
  if(body<1)return [['M',left,0],['L',right,0],['L',right,b-r],['Q',right,b,right-r,b],['L',left+r,b],['Q',left,b,left,b-r],['Z']];
  return [['M',left,0],['L',right,0],['L',right,b-4],['Q',right,b,right+flare,b],
    ['C',right+control,b+shoulder/2,x+w,b,x+w,b+shoulder],['L',x+w,h-radius],
    ['Q',x+w,h,x+w-radius,h],['L',x+radius,h],['Q',x,h,x,h-radius],['L',x,b+shoulder],
    ['C',x,b,left-control,b+shoulder/2,left-flare,b],['Q',left,b,left,b-4],['Z']];
}
function silhouette(frame){return contour(frame).map(s=>s.join(' ')).join(' ');}
function contourPoints(frame) {
  const points=[];let start,last;
  for(const [type,...v] of contour(frame)){
    if(type==='M'||type==='L'){last={x:v[0],y:v[1]};points.push(last);if(type==='M')start=last;}
    else if(type==='Z'){points.push(start);last=start;}
    else {
      const from=last,steps=16;
      for(let i=1;i<=steps;i++){const t=i/steps,u=1-t;
        last=type==='Q'?{x:u*u*from.x+2*u*t*v[0]+t*t*v[2],y:u*u*from.y+2*u*t*v[1]+t*t*v[3]}:
          {x:u*u*u*from.x+3*u*u*t*v[0]+3*u*t*t*v[2]+t*t*t*v[4],y:u*u*u*from.y+3*u*u*t*v[1]+3*u*t*t*v[3]+t*t*t*v[5]};
        points.push(last);
      }
    }
  }
  return points;
}
function contains(frame,point) {
  const x=point.x-frame.x,y=point.y-frame.y,points=contourPoints(frame);let inside=false;
  for(let i=0,j=points.length-1;i<points.length;j=i++){
    const a=points[j],b=points[i],cross=(x-a.x)*(b.y-a.y)-(y-a.y)*(b.x-a.x);
    if(Math.abs(cross)<1e-7 && x>=Math.min(a.x,b.x)&&x<=Math.max(a.x,b.x)&&y>=Math.min(a.y,b.y)&&y<=Math.max(a.y,b.y))return true;
    if((a.y>y)!==(b.y>y) && x<(b.x-a.x)*(y-a.y)/(b.y-a.y)+a.x)inside=!inside;
  }
  return inside;
}

function modelLines(raw = '') {
  const gpt = /^gpt-(\d+(?:\.\d+)?)(?:-(.+))?$/i.exec(raw);
  if (gpt) return [`GPT-${gpt[1]}`, (gpt[2] || '').replace(/-/g, ' ').toUpperCase()];
  const dsh = /^deepseek[- ](.+)$/i.exec(raw);
  if (dsh) return ['DeepSeek', dsh[1].replace(/-/g, ' ').toUpperCase()];
  const words = raw.trim().split(/[ -]+/);
  return words.length > 1 ? [words[0], words.slice(1).join(' ')] : [raw || '等待模型', ''];
}
function compactNumber(value) {
  if (!Number.isFinite(value)) return '--';
  const abs = Math.abs(value);
  if (abs >= 1e9) return `${(value / 1e9).toFixed(1).replace(/\.0$/, '')}B`;
  if (abs >= 1e6) return `${(value / 1e6).toFixed(1).replace(/\.0$/, '')}M`;
  if (abs >= 1e3) return `${(value / 1e3).toFixed(1).replace(/\.0$/, '')}K`;
  return String(Math.round(value));
}
function quotaLabel(value) {
  if (!Number.isFinite(value)) return '--';
  const n = Math.max(0, Math.min(100, value));
  return n > 0 && n < 1 ? '<1%' : `${Math.round(n)}%`;
}
const api={Spring,layout,contains,silhouette,contourPoints,modelLines,compactNumber,quotaLabel};
if(typeof module==='object'&&module.exports)module.exports=api;else root.tokenLensGeometry=api;
})(typeof globalThis!=='undefined'?globalThis:this);
