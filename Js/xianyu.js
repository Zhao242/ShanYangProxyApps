/**
 * 闲鱼 去广告+净化
 * 2024-08-11 13:00:37
 */
const url = $request.url;
let body = $response.body;
let obj = JSON.parse(body);

// 首页信息流广告处理
if (url.includes("/gw/mtop.taobao.idlehome.home.nextfresh")) {
  delete obj.data.widgetReturnDO;  // 删除首页标签
  if (obj.data?.sections) {
    obj.data.sections = obj.data.sections.filter(section => {
      return !(section.data && (section.data.bizType === "AD" || section.data.bizType === "homepage"));
    });
  }
}

// 定位地区页面的信息流广告
if (url.includes("/gw/mtop.taobao.idle.local.home")) {
  if (obj.data?.sections) {
    obj.data.sections = obj.data.sections.filter(section => {
      return !(section.data && section.data.bizType === "AD");
    });
  }
}

// 首页顶部标签
if (url.includes("/gw/mtop.taobao.idle.home.whale.modulet")) {
  delete obj.data.container.sections;
}

// 搜索栏和闲鱼币入口处理
if (url.includes("/gw/mtop.taobao.idlemtopsearch.search.shade") || url.includes("/gw/mtop.taobao.idle.user.strategy.list")) {
  delete obj.data;
}

// 个人主页处理
const user = "/mtop.idle.user.page.my.adapter";
if (url.includes(user)) {
  obj.data.container.sections = obj.data.container.sections.filter(item => item.index !== "6");
  obj.data.container.sections.forEach(section => {
    if (section.index === "1") {
        delete section.item.level;  // 删除个人等级
    }
  });
  obj.data.container.sections = obj.data.container.sections.filter(item => item.index !== "5");
}

// 旧版首页顶部频道菜单处理
const circle = "/mtop.taobao.idlehome.home.circle.list";
if (url.includes(circle)) {
  if (obj.data && obj.data.circleList) {
    obj.data.circleList.forEach(circle => {
      if (circle.showType) {
        circle.showType = "text";  // 设置展示类型为文本
      }
      if (circle.showInfo && circle.showInfo.titleImage) {
        delete circle.showInfo.titleImage;  // 删除标题图片
      }
    });
  }
}

body = JSON.stringify(obj);
$done({body});
