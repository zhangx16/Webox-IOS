// XPTV compatible script shape (getConfig / getCards / getTracks / getPlayinfo).
// WeBox detects it automatically and attaches it through runtime/xptv.js.
function app() {
  return { title: 'XPTV 公开示例', ver: '1.0', site: 'https://example.com', mediaType: 'movie' };
}

async function getConfig() {
  return {
    title: 'XPTV 公开示例',
    tabs: [
      { name: '全部', ext: { id: 'all' } },
      { name: '短片', ext: { id: 'short' } }
    ]
  };
}

async function getCards(params) {
  return {
    list: [
      { vod_id: 'bunny', vod_name: 'Big Buck Bunny', vod_pic: 'https://peach.blender.org/wp-content/uploads/title_anouncement.jpg', vod_remarks: '开放电影' }
    ]
  };
}

async function getTracks(ext) {
  return [{ title: '默认线路', tracks: [{ name: '正片', ext: { id: 'bunny' } }] }];
}

async function getPlayinfo(ext) {
  return { urls: ['https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4'],
           names: ['公开测试线路'] };
}
