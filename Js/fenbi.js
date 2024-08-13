/*
 * 粉笔各首页模块优化 去除不必要滑块
 * 2024/8/12
 */

const url = $request.url; // 获取请求的 URL
const body = $response.body; // 获取响应的 body
let obj = JSON.parse(body); // 将 body 解析为 JSON 对象


if (url.includes('https://keapi.fenbi.com/app/iphone/xingce/small_banner')) {
    if (obj.data && obj.data.items) {
        obj.data.items = [];
    }
}


else if (url.includes('https://tiku.fenbi.com/iphone/xingce/banners/v2')) {
    if (obj.banners && obj.banners.datas) {
        obj.banners.datas = [];
    }
}

// 处理其他请求，过滤 cover 数组，只保留特定类型
else if (url.includes('https://tiku.fenbi.com/iphone/xingce/course/module/config/v2')) {
    const allowedTypes = ["jam", "paper", "template","pk"];
    if (obj.cover && Array.isArray(obj.cover)) {
        obj.cover = obj.cover.filter(item => allowedTypes.includes(item.type));
    }
}

// 将修改后的对象转换回 JSON 字符串
const newBody = JSON.stringify(obj);

// 返回修改后的响应
$done({body: newBody});