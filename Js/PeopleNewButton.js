/**
 * PDNews API 广告去除和底部导航定制
 * 2024-08-11
 */
const url = $request.url;
let body = $response.body;
let obj = JSON.parse(body);

// 针对pageInfo的响应去除广告和其他不需要的部分
if (url.includes("https://pdapis.pdnews.cn/api/rmrb-bff-display-zh/display/zh/c/pageInfo/v2")) {
  if (obj.data) {
    // 清空 compAdList
    if (obj.data.compInfo && obj.data.compInfo.compAdList) {
      obj.data.compInfo.compAdList = [];
    }

    // 清空 cornersAdv
    if (obj.data.cornersAdv) {
      obj.data.cornersAdv = {};
    }

    // 清空 cornersAdv2
    if (obj.data.cornersAdv2) {
      obj.data.cornersAdv2 = [];
    }

    // 清空 channelInfo
    if (obj.data.channelInfo) {
      obj.data.channelInfo = {};
    }
  }
  body = JSON.stringify(obj);
  $done({body});
} else if (url.includes("https://pdapis.pdnews.cn/api/rmrb-bff-display-zh/display/zh/c/bottomNavGroup")) {
  // 针对bottomNavGroup的响应过滤底部导航
  if (obj.data && obj.data.bottomNavList) {
    obj.data.bottomNavList = obj.data.bottomNavList.filter(item => item.name !== "人民号" && item.name !== "视频");
  }
  body = JSON.stringify(obj);
  $done({body: body});
} else {
  // 如果URL不匹配，直接返回未修改的响应
  $done({});
}
