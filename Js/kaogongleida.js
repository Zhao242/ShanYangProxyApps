
const requestUrl = "https://api.gongkaoleida.com/api/v5_4_8/index/jobs";
const responseUrl = "https://api.gongkaoleida.com/api/v5_4_8/user/resume?";


if ($request.url.indexOf(requestUrl) !== -1) {
  let modifiedUrl = $request.url.replace(/superFilterCount=\d+/, 'superFilterCount=1');
  $done({url: modifiedUrl});
}


if ($request.url.indexOf(responseUrl) !== -1) {
  // Parse the response
  let body = JSON.parse($response.body);


  body.data.userInfo.vipGrade = 2;  // Set to 星钻VIP
  body.data.userInfo.isVip = 1;     // Set VIP status to true
  body.data.userInfo.vipGradeList[1].isVip = 1;
  body.data.userInfo.vipGradeList[1].remainDays = 365; // Optional: Set VIP to valid for 365 days
  body.data.userInfo.vipExpire = 1893456000; // Set a future expire date (example timestamp)


  $done({body: JSON.stringify(body)});
} else {
  // If the URL doesn't match, proceed with the response unmodified
  $done({});
}
