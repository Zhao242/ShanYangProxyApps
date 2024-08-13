/*
 * 粉笔各首页模块优化 去除不必要滑块
 * 2024/8/12
 */
const url = $request.url; 
const body = $response.body; 
let obj = JSON.parse(body); 

function filterItemsByKey(array, key, allowedValues) {
    if (Array.isArray(array)) {
        return array.filter(item => allowedValues.includes(item[key]));
    }
    return [];
}

if (url.includes('https://keapi.fenbi.com/app/iphone/xingce/small_banner')) {
    if (obj.data && Array.isArray(obj.data.items)) {
        obj.data.items = [];
    }
}
else if (url.includes('https://tiku.fenbi.com/iphone/xingce/banners/v2')) {
    if (obj.banners && Array.isArray(obj.banners.datas)) {
        obj.banners.datas = [];
    }
}
else if (url.includes('https://tiku.fenbi.com/iphone/xingce/course/module/config/v2')) {
    const allowedTypes = ["jam", "paper", "template", "pk"];
    if (obj.cover) {
        obj.cover = filterItemsByKey(obj.cover, 'type', allowedTypes);
    }
}

const newBody = JSON.stringify(obj);
$done({body: newBody});
