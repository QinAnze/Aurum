// SDK 错误摘要统一使用平台显示名称。
export function providerName(id) {
    return { netease: '网易云音乐', qq: 'QQ 音乐', kugou: '酷狗音乐' }[id] || '网易云音乐';
}
