/**
 * 咪咕音乐滚动广告
 * 2024-10-08
 */
const url = $request.url;
const body = $response.body;
let obj = JSON.parse(body);

function filterItemsByKey(array, key, disallowedValue) {
    if (Array.isArray(array)) {
        return array.filter(item => item[key] !== disallowedValue);
    }
    return [];
}

if (url.includes('https://app.pd.nf.migu.cn/MIGUM3.0/bmw/page-data/index-show')) {
    if (obj && obj.data && obj.data.contents) {
        obj.data.contents.forEach(column => {
            if (column.contents) {
                column.contents = filterItemsByKey(column.contents, 'view', 'ZJ-Banner-Item');
            }
        });
    }
}
const newBody = JSON.stringify(obj);
$done({ body: newBody });
