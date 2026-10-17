// 只适配三平台歌词接口；缓存、补词选择、播放同步和显示状态均在 Qt 内。
export async function fetchLyrics(api, provider, track) {
    const metadata = { title: track.title, artist: track.artist };
    let body;
    if (provider === 'qq') {
        body = await api.request('/getLyric', { songmid: track.id, isFormat: false, ...metadata });
    } else if (provider === 'kugou') {
        const search = await api.request('/search/lyric', {
            hash: track.id,
            keywords: track.title,
            duration: track.duration || 0,
            album_audio_id: track.albumAudioID || 0,
        });
        const candidates = search.candidates || search.data?.candidates || [];
        const match = candidates.find((candidate) => candidate.id && candidate.accesskey);
        if (!match) {
            return null;
        }
        body = await api.request('/lyric', {
            id: match.id,
            accesskey: match.accesskey,
            fmt: 'krc',
            decode: true,
            ...metadata,
        });
        if (!body.document?.lines?.length) {
            body = await api.request('/lyric', {
                id: match.id,
                accesskey: match.accesskey,
                fmt: 'lrc',
                decode: true,
                ...metadata,
            });
        }
    } else {
        try {
            body = await api.request('/lyric/new', { id: track.id, ...metadata });
        } catch (error) {
            // 新接口失败时回退锁定的逐句接口，不改变歌词解析协议。
            body = await api.request('/lyric', { id: track.id, ...metadata });
        }
    }
    return body?.document || null;
}
