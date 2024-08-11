/**
 * 人民日报 广告去除和底部导航定制 - Surge 脚本
 * 2024-08-11
 */
const url = $request.url;
let body = $response.body;
let obj;

try {
  obj = JSON.parse(body);
} catch (e) {
  // If parsing fails, return the original body
  $done({ body });
  return;
}

// 针对pageInfo的响应去除广告列表
if (url.includes("/api/rmrb-bff-display-zh/display/zh/c/pageInfo/v2")) {
  if (obj.data && obj.data.compAdList) {
    obj.data.compAdList = [];  // 这里是你需要去除的内容
  }
  body = JSON.stringify(obj);
  $done({ body });
} else if (url.includes("/api/rmrb-bff-display-zh/display/zh/c/bottomNavGroup")) {
  // 针对bottomNavGroup的响应过滤底部导航
  if (obj.data && obj.data.bottomNavList) {
    obj.data.bottomNavList = obj.data.bottomNavList.filter(item => item.name !== "人民号" && item.name !== "视频");
  }
  body = JSON.stringify(obj);
  $done({ body });
} else {
  // 如果URL不匹配，直接返回未修改的响应
  $done({ body });
}
