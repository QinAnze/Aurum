import assert from 'node:assert/strict';
import format from '../../MusicBridge/lyrics-format.cjs';

// 真实平台形态包含重复副歌、多精度时间、偏移、实体、翻译与间奏。
const lrc = '[offset:200]\r\n[00:01.5][00:04.500]第一句 &amp; 第二声\r\n[00:03.00]\r\n[00:05]结束';
const document = format.normalizeLyrics('netease', { lrc: { lyric: lrc } }).document;
assert.deepEqual(
    document.lines.map((line) => line.startMs),
    [1500, 3000, 4500, 5000],
);
assert.equal(document.lines[0].text, '第一句 & 第二声');
assert.equal(document.lines[1].text, '');

const yrc = format.normalizeLyrics('netease', {
    yrc: { lyric: '[1000,2000](1000,500,0)第一(1500,1500,0)句\n[4000,1000](4000,1000,0)第二句' },
    ytlrc: { lyric: '[00:01.00]译文一\n[00:04.00]译文二' },
}).document;
assert.equal(yrc.timing, 'word');
assert.equal(yrc.lines[0].endMs, 3000);
assert.equal(yrc.lines[0].translation, '译文一');
const krc = format.normalizeLyrics('kugou', {
    decodeContent: '[1000,2000]<0,500,0>第一<500,1500,0>句\n[4000,1000]<0,1000,0>第二句',
}).document;
assert.deepEqual(
    krc.lines.map((line) => line.words),
    yrc.lines.map((line) => line.words),
);
const qq = format.normalizeLyrics('qq', {
    response: {
        lyric: '[00:01.0]原文\n[00:02.00]第二句',
        trans: Buffer.from('[00:01.0]翻译').toString('base64'),
    },
}).document;
assert.equal(qq.lines[0].translation, '翻译');
assert.equal(format.normalizeLyrics('qq', { lyric: '只有文字\n没有时间' }).document.timing, 'none');
assert.equal(format.normalizeLyrics('qq', { lyric: '[00:00.00]一\n[00:00.00]二' }).document.timing, 'none');
const credits = format.normalizeLyrics('qq', {
    lyric:
        '[ti:回家的路]\n[ar:HOYO-MiX]\n[00:00.07]回家的路 - HOYO-MiX\n' +
        '[00:00.29]作词 Lyricist：木木\n[00:00.67]当你走上回家的路\n[00:04.03]星星发着光',
}).document;
assert.deepEqual(
    credits.lines.map((line) => line.startMs),
    [670, 4030],
);

console.log('三平台歌词格式、偏移字段、翻译和逐词时标解析通过');
