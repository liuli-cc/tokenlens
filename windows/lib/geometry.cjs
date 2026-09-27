'use strict';

// Analytic damped spring: preserves velocity on retargeting and does not depend
// on the display refresh rate. Coordinates remain centred on the same axis.
class Spring {
  constructor(value = 0, damping = 0.68, frequency = 19) {
    this.value = value; this.velocity = 0; this.target = value;
    this.damping = damping; this.frequency = frequency;
  }
  step(dt) {
    const w = this.frequency, z = this.damping, wd = w * Math.sqrt(1 - z * z);
    const y = this.value - this.target, b = (this.velocity + z * w * y) / wd;
    const decay = Math.exp(-z * w * dt), s = Math.sin(wd * dt), c = Math.cos(wd * dt);
    this.value = this.target + decay * (y * c + b * s);
    this.velocity = decay * ((-y * wd * s + b * wd * c) - z * w * (y * c + b * s));
    if (Math.abs(this.value - this.target) < 0.0005 && Math.abs(this.velocity) < 0.005) {
      this.value = this.target; this.velocity = 0;
    }
    return this.value;
  }
}

function layout(workArea, progress = 0) {
  const neck = Math.max(140, Math.min(280, workArea.width - 24));
  const maximum = Math.min(460, workArea.width - 24);
  const p = Math.max(0, progress);
  const width = Math.max(neck, Math.min(workArea.width - 16, neck + (maximum - neck) * p));
  const band = 36, body = 164 * p;
  return { x: Math.round(workArea.x + workArea.width / 2 - width / 2), y: workArea.y,
    width: Math.round(width), height: Math.max(band, Math.round(band + body)), neck, band, body, progress: p };
}

function contains(frame, point) {
  const x = point.x - frame.x, y = point.y - frame.y, {width: w, height: h, neck, band} = frame;
  if (x < 0 || x > w || y < 0 || y > h) return false;
  if (y <= band) return Math.abs(x - w / 2) <= neck / 2;
  const radius = Math.min(28, Math.max(0, (h - band) / 2));
  if (y >= h - radius && (x < radius || x > w - radius)) {
    const cx = x < radius ? radius : w - radius;
    return (x - cx) ** 2 + (y - (h - radius)) ** 2 <= radius ** 2;
  }
  // Shoulder curves leave the transparent top corners click-through.
  const shoulder = Math.min(16, (h - band) / 2);
  if (y < band + shoulder && (x < (w - neck) / 2 || x > (w + neck) / 2)) {
    const t = (y - band) / Math.max(1, shoulder);
    return Math.abs(x - w / 2) <= neck / 2 + (w - neck) / 2 * Math.sqrt(t);
  }
  return true;
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
module.exports = { Spring, layout, contains, modelLines, compactNumber, quotaLabel };
