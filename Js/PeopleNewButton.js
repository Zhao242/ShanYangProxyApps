const url = $request.url;
function handleResponse(body) {
    let obj = JSON.parse(body);

    // 检查是否存在bottomNavList，并进行处理
    if (obj.data && obj.data.bottomNavList) {
        // 过滤掉名为"人民号"和"视频"的条目
        obj.data.bottomNavList = obj.data.bottomNavList.filter(item => item.name !== "人民号" && item.name !== "视频");
    }

    return JSON.stringify(obj); 
}

// 判断是否是目标URL
if (url.includes("https://pdapis.pdnews.cn/api/rmrb-bff-display-zh/display/zh/c/bottomNavGroup")) {
    let modifiedBody = handleResponse($response.body);
    $done({body: modifiedBody});
} else {
    $done({});
}
