'use strict';
// Pure text helpers for the wake-word daemon (no native deps, unit-testable).

function normalise(text) {
  return String(text).replace(/[\s\u3000]/g, '');
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Allow blanks/punctuation between trigger characters, matching how ASR splits phrases.
function triggerPattern(trigger) {
  const body = [...trigger].map(escapeRe).join('[\\s,，。.、]*');
  return new RegExp(body, 'i');
}

function findTrigger(triggers, raw) {
  for (const t of triggers) {
    const m = triggerPattern(t).exec(raw);
    if (m) return { trigger: t, index: m.index, length: m[0].length };
  }
  return null;
}

function isCancel(cancelWords, raw) {
  const n = normalise(raw);
  return cancelWords.some((w) => n.includes(normalise(w)));
}

function stripCommand(raw, maxChars = 400) {
  return String(raw)
    .replace(/^[\s,，。.、!！?？~～:：;；\-—]+/, '')
    .replace(/[\s,，。.、]+$/, '')
    .trim()
    .slice(0, maxChars);
}

// 去掉开头的唤醒词: 待命时用户常把唤醒词再说一遍(或 ASR 漏字), 指令里不该带它
function stripLeadingTrigger(triggers, raw) {
  const hit = findTrigger(triggers, raw);
  if (!hit) return raw;
  if (raw.slice(0, hit.index).trim().length > 0) return raw;
  return raw.slice(hit.index + hit.length);
}

// 纠正 ASR 对英文 ID / 专有名词的误写(长键优先, 避免短键先吃掉)
function applyCorrections(corrections, raw) {
  if (!corrections) return raw;
  const keys = Object.keys(corrections).sort((a, b) => b.length - a.length);
  let out = String(raw);
  for (const key of keys) {
    if (!key) continue;
    out = out.replace(new RegExp(escapeRe(key), 'gi'), corrections[key]);
  }
  return out;
}

module.exports = { normalise, escapeRe, triggerPattern, findTrigger, isCancel, stripCommand, stripLeadingTrigger, applyCorrections };
