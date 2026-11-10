// WeBox Script 1.0 example — public test streams, no real site scraping.
// Import this file in 设置 → 导入内容源 → 本地文件 to smoke-test the iOS port.
WeBox.define({
  api: '1.0',
  id: 'demo.webox.ios',
  name: '公开示例',
  version: '1.0.0',
  allowHttp: false,
  settings: {
    fields: [
      { key: 'note', label: '备注（可选）', type: 'text', default: '' }
    ]
  },
  filters: function () {
    return [
      { key: 'group', label: '内容分类', type: 'select', default: 'all',
        options: [{ label: '全部', value: 'all' }, { label: '短片', value: 'short' }] }
    ];
  },
  list: async function (ctx, request) {
    var shortOnly = request.filters.group === 'short';
    var items = [
      { id: 'bunny', title: 'Big Buck Bunny', kind: 'movie',
        poster: 'https://peach.blender.org/wp-content/uploads/title_anouncement.jpg',
        subtitle: 'Blender 基金会 · 公开测试视频' }
    ];
    if (!shortOnly) {
      items.push({ id: 'bipbop', title: 'Apple BipBop（HLS）', kind: 'movie',
        subtitle: 'HLS 测试流 · 多码率' });
    }
    return { items: items, nextCursor: null };
  },
  search: async function (ctx, request) {
    var word = String(request.query || '').toLowerCase();
    var all = [
      { id: 'bunny', title: 'Big Buck Bunny', kind: 'movie' },
      { id: 'bipbop', title: 'Apple BipBop（HLS）', kind: 'movie' }
    ];
    return { items: all.filter(function (item) { return item.title.toLowerCase().indexOf(word) >= 0; }),
             nextCursor: null };
  },
  detail: async function (ctx, request) {
    var titles = { bunny: 'Big Buck Bunny', bipbop: 'Apple BipBop（HLS）' };
    return {
      id: request.id,
      title: titles[request.id] || '公开示例',
      kind: 'movie',
      summary: '公开测试用视频，用于验证列表、详情、播放与下载流程。',
      groups: [{ id: 'main', name: '正片', episodes: [{ id: request.id + '-full', name: '正片' }] }]
    };
  },
  play: async function (ctx, request) {
    if (request.contentId === 'bipbop') {
      return { sources: [{
        id: 'hls', name: 'Apple HLS 测试流',
        url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8',
        mime: 'application/x-mpegURL'
      }] };
    }
    return { sources: [{
      id: 'mp4', name: 'Blender 开放电影',
      url: 'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4',
      mime: 'video/mp4'
    }] };
  }
});
