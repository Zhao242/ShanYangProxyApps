const ddm = JSON.parse($response.body);
const ua = $request.headers["User-Agent"] || $request.headers["user-agent"];
const bundle_id = ddm.receipt["bundle_id"] || ddm.receipt["Bundle_Id"];
const yearid = `${bundle_id}.year`;
const yearlyid = `${bundle_id}.yearly`;
const yearlysubscription = `${bundle_id}.yearlysubscription`;
const lifetimeid = `${bundle_id}.lifetime`;

const list = {
  'ChickAlarmClock': { cm: 'timea', hx: 'hxpda', id: "com.ChickFocus.ChickFocus.yearly_2023_promo", latest: "ddm1023" }  
};