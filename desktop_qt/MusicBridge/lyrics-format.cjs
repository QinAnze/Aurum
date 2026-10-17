// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
// Adapted from LyricsKit (MxIris-LyricsX-Project), revision recorded in lyrics-source.json.
// LyricsCore 和 LyricsService 的 LRC、YRC、KRC 解析步骤
const MAX_CONTENT_LENGTH = 1000000;

function cleanText(value) {
    return String(value || '')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&#(x[0-9a-f]+|\d+);/gi, (match, code) => {
            const point = code[0].toLowerCase() === 'x' ? parseInt(code.slice(1), 16) : Number(code);
            return point <= 0x10ffff ? String.fromCodePoint(point) : match;
        })
        .replace(/&amp;/g, '&')
        .replace(/\r\n?/g, '\n')
        .slice(0, MAX_CONTENT_LENGTH);
}

function parseTags(content) {
    const tags = {};
    for (const match of content.matchAll(/^\s*\[([a-z]+):([^\]\n]*)\]\s*$/gim)) {
        tags[match[1].toLowerCase()] ??= match[2].trim();
    }
    return tags;
}

/**
 * 沿用 LyricsCore 的多时间标签展开与稳定排序，额外保留空行作为间奏边界。
 * 所有格式在进入同步引擎前统一为绝对毫秒时间。
 */
function parseLrc(input) {
    const content = cleanText(input);
    const lines = [];
    for (const row of content.split('\n')) {
        const match = /^\s*((?:\[[-+]?\d+:\d+(?:[.:]\d+)?\])+)(.*)$/.exec(row);
        if (!match) {
            continue;
        }
        const translation = /【(.*)】$/.exec(match[2]);
        const text = match[2].replace(/【.*】$/, '').trim();
        for (const stamp of match[1].matchAll(/\[([-+]?\d+):(\d+)(?:[.:](\d+))?\]/g)) {
            const startMs = Math.round(
                (Number(stamp[1]) * 60 + Number(stamp[2])) * 1000 + Number('0.' + (stamp[3] || '0')) * 1000,
            );
            lines.push({ startMs, endMs: null, text, translation: translation?.[1] || '', words: [] });
        }
    }
    return lines.sort((left, right) => left.startMs - right.startMs);
}

/**
 * 网易云 YRC 与酷狗 KRC 行、词时间解析。
 * KRC 词起点相对行起点，YRC 词起点是绝对时间。
 */
function parseWordLyrics(input, format) {
    const lines = [];
    for (const row of cleanText(input).split('\n')) {
        const match = /^\[(\d+),(\d+)\](.*)$/.exec(row);
        if (!match) {
            continue;
        }
        const startMs = Number(match[1]);
        const endMs = startMs + Number(match[2]);
        const words = [];
        const expression = format === 'krc' ? /<(\d+),(\d+),\d+>([^<]*)/g : /\((\d+),(\d+),\d+\)([^()]*)/g;
        for (const token of match[3].matchAll(expression)) {
            const wordStart = Number(token[1]) + (format === 'krc' ? startMs : 0);
            words.push({ startMs: wordStart, endMs: wordStart + Number(token[2]), text: token[3] });
        }
        if (words.length) {
            lines.push({
                startMs,
                endMs,
                text: words
                    .map((word) => word.text)
                    .join('')
                    .trim(),
                translation: '',
                words,
            });
        }
    }
    return lines.sort((left, right) => left.startMs - right.startMs);
}

function attachTranslation(lines, translation) {
    const translated = parseLrc(translation);
    // 对齐到同一来源的最近时间标签，避免按数组下标拼接导致缺行后整体错位。
    for (const line of lines) {
        let closest = null;
        let distance = 700;
        for (const candidate of translated) {
            const delta = Math.abs(line.startMs - candidate.startMs);
            if (candidate.text && delta < distance) {
                closest = candidate;
                distance = delta;
            }
        }
        if (closest) {
            line.translation = closest.text;
        }
    }
}

function isCreditLine(line, tags) {
    const text = line.text.trim();
    const role =
        /^(作词|作曲|编曲|制谱|演唱|制作人|录音棚|录音师|混音师|母带制作|民谣吉他|电吉他|手风琴|第一小提琴|第二小提琴|中提琴|大提琴|词|曲|lyrics by|composed by|written by|produced by|arranged by)(?:\s+[^:：]+)?\s*[:：]/i;
    if (role.test(text)) {
        return true;
    }
    const title = tags.ti?.trim();
    const artist = tags.ar?.trim();
    return !!title && !!artist && text === title + ' - ' + artist;
}

/**
 * 把锁定 API 已解码的响应转换为公共歌词文档。
 */
function normalizeLyrics(provider, body, metadata = {}) {
    const raw = body.response || body;
    if (raw.code !== undefined && ![0, 200].includes(raw.code)) {
        return { code: 502, message: '歌词来源暂不可用' };
    }
    let original = '';
    let wordContent = '';
    let format = 'lrc';
    let translation = '';
    if (provider === 'netease') {
        original = raw.lrc?.lyric || '';
        wordContent = raw.yrc?.lyric || '';
        format = 'yrc';
        translation = raw.ytlrc?.lyric || raw.tlyric?.lyric || '';
    } else if (provider === 'qq') {
        original = raw.lyric || '';
        translation = raw.trans ? Buffer.from(raw.trans, 'base64').toString('utf8') : '';
    } else {
        original = raw.decodeContent || '';
        wordContent = original;
        format = 'krc';
    }
    original = cleanText(original);
    const wordLines = parseWordLyrics(wordContent, format);
    let lines = wordLines.length ? wordLines : parseLrc(original);
    attachTranslation(lines, translation);
    if (provider === 'kugou') {
        const language = /^\[language:([^\]\n]+)\]/m.exec(original);
        if (language) {
            try {
                const tracks = JSON.parse(Buffer.from(language[1], 'base64').toString('utf8')).content;
                const translated = tracks?.find((track) => track.type === 1)?.lyricContent || [];
                translated.slice(0, lines.length).forEach((text, index) => {
                    lines[index].translation = text.join('').trim();
                });
            } catch (error) {
                // 附属翻译损坏不影响原文时间轴，保留无翻译的歌词。
            }
        }
    }
    const tags = parseTags(wordLines.length ? wordContent : original);
    tags.ti ||= metadata.title;
    tags.ar ||= metadata.artist;
    // 只移除具有明确角色或文件头身份的署名，不按零秒或时间阈值删除真正的开头歌词。
    lines = lines.filter((line) => !isCreditLine(line, tags));
    const offsetMs = Number(tags.offset || 0);
    const hasContent = lines.some(
        (line) =>
            line.text &&
            !/^(作词|作曲|编曲|制作人|演唱|混音|录音)\s*[:：]/.test(line.text) &&
            !/^(纯音乐|此歌曲为没有填词的纯音乐)/.test(line.text),
    );
    const timed = hasContent && new Set(lines.map((line) => line.startMs)).size > 1;
    const plainText = timed
        ? ''
        : original
              .replace(/^\[[a-z]+:.*\]\s*$/gim, '')
              .replace(/\[[^\]\n]+\]/g, '')
              .trim();
    let timing = 'none';
    if (timed) {
        timing = wordLines.length ? 'word' : 'line';
    }
    return {
        code: 200,
        document: {
            version: 1,
            source: provider,
            timing,
            offsetMs: Number.isFinite(offsetMs) && Math.abs(offsetMs) <= 10000 ? offsetMs : 0,
            lines: timed ? lines : [],
            plainText,
        },
    };
}

module.exports = { parseLrc, parseWordLyrics, normalizeLyrics };
