import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createWebServer } from '../server.mjs';
import { fixture, listen } from './fixture.mjs';
import { T } from '../public/domain.mjs';

const chromium=process.argv[2];
if (!chromium) throw new Error('请传入 Chrome 或 Edge 可执行文件路径');
const output=resolve(process.argv[3]||'.web-browser-test');
await mkdir(output,{recursive:true});
const profile=await mkdtemp(join(output,'profile-'));
const backend=fixture();
const upstream=await listen(backend.server);
const gateway=createWebServer({upstream});
const origin=await listen(gateway);
const browser=spawn(chromium,['--headless=new','--remote-debugging-pipe','--no-first-run','--no-default-browser-check',
  '--disable-background-networking','--disable-extensions','--disable-gpu','--user-data-dir='+profile,'about:blank'],{
  stdio:['ignore','ignore','pipe','pipe','pipe'],windowsHide:true,
});
const waiting=new Map(), errors=[];
let id=0,buffer=Buffer.alloc(0);
let debug='';
browser.stderr.on('data',part=>{debug=(debug+part.toString()).slice(-2600);});
browser.stdio[4].on('data',part=>{
  buffer=Buffer.concat([buffer,part]);
  while (buffer.includes(0)) {
    const boundary=buffer.indexOf(0);
    const raw=buffer.subarray(0,boundary);
    buffer=buffer.subarray(boundary+1);
    if (!raw.length) continue;
    const event=JSON.parse(raw);
    const request=waiting.get(event.id);
    if (request) {
      waiting.delete(event.id);
      clearTimeout(request.timer);
      if (event.error) request.reject(new Error(event.error.message)); else request.resolve(event.result);
    }
    if (event.method==='Runtime.exceptionThrown') errors.push(event.params.exceptionDetails.exception?.description||event.params.exceptionDetails.text);
  }
});
function call(method,params={},sessionId) {
  return new Promise((resolve,reject)=>{
    const key=++id;
    const timer=setTimeout(()=>{waiting.delete(key);reject(new Error(method+' 未响应\n'+debug));},12_000);
    waiting.set(key,{resolve,reject,timer});
    browser.stdio[3].write(JSON.stringify({id:key,method,params,sessionId})+'\0');
  });
}
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let sessionId;
async function evaluate(expression) {
  const {result,exceptionDetails}=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},sessionId);
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description||exceptionDetails.text);
  return result.value;
}
async function expectPage(condition,label) {
  for(let i=0;i<60;i++) {
    if (await evaluate(condition)) return;
    await delay(100);
  }
  throw new Error(label+'\n'+await evaluate('document.body.innerText')+'\n'+errors.join('\n'));
}
const choose=async selector=>evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
const goto=async page=>{await evaluate(`location.hash=${JSON.stringify(page)}`);await expectPage(`!!document.querySelector('.page-${page}')`,page);};
const set=async (select,value)=>evaluate(`(() => {const field=document.querySelector(${JSON.stringify(select)});field.value=${JSON.stringify(value)};
  field.dispatchEvent(new Event('input',{bubbles:true}));})()`);
const submit=async selector=>evaluate(`document.querySelector(${JSON.stringify(selector)}).requestSubmit()`);
const content=(selector,text)=>`document.querySelector(${JSON.stringify(selector)})?.textContent.includes(${JSON.stringify(text)})`;
async function wheel(selector,deltaY) {
  const point=await evaluate(`(() => {const b=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
    return {x:b.left+b.width/2,y:b.top+Math.min(b.height/2,80)};})()`);
  await call('Input.dispatchMouseEvent',{type:'mouseWheel',...point,deltaX:0,deltaY},sessionId);
}
async function screenshot(name,width=1440,height=930) {
  await call('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false},sessionId);
  await delay(150);
  const {data}=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},sessionId);
  await writeFile(join(output,name+'.png'),Buffer.from(data,'base64'));
}

try {
  const {targetId}=await call('Target.createTarget',{url:'about:blank'});
  ({sessionId}=await call('Target.attachToTarget',{targetId,flatten:true}));
  await call('Runtime.enable',{},sessionId);
  await call('Page.enable',{},sessionId);
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:930,deviceScaleFactor:1,mobile:false},sessionId);
  await call('Page.navigate',{url:origin},sessionId);
  await expectPage('document.querySelector("canvas")?.width > 150','登录二维码');
  await screenshot('login');
  backend.approve();
  await expectPage(content('#quadrant-2','整理本周的工作计划'),'任务同步进重要象限');
  await expectPage(`document.querySelectorAll('.task-quadrant').length===4 &&
    !document.querySelector('.calendar-card') &&
    !!document.querySelector('[data-filter=open][aria-pressed=true]')`,'任务默认待完成且无日历');
  await choose('.quadrant-add[data-rank="4"]');
  await expectPage(`document.querySelector('#modal-form [name=rank]')?.value==='4'`,'象限新增预选优先级');
  await choose('#dialog .dialog-head [data-act=close]');
  await screenshot('tasks');
  await goto('timeline');
  await expectPage('document.querySelector(".calendar-card").getBoundingClientRect().right < document.querySelector(".tasks-card").getBoundingClientRect().left','日历左、任务列表右');
  const monthMarks=await evaluate(`Array.from(document.querySelectorAll('.calendar-day:not(.outside)')).map(day=>[day.dataset.date,!!day.querySelector('.has-tasks')])`);
  await choose('[data-act=calendar-view][data-view=year]');
  await expectPage('document.querySelectorAll(".mini-month").length===12','年视图 12 个月');
  const yearMarks=Object.fromEntries(await evaluate(`Array.from(document.querySelectorAll('.mini-day')).map(day=>[day.dataset.date,day.classList.contains('has-tasks')])`));
  assert.ok(monthMarks.some(([,marked])=>marked) && monthMarks.some(([,marked])=>!marked));
  for(const [day,marked] of monthMarks) assert.equal(yearMarks[day],marked,day);
  await expectPage(`getComputedStyle(document.querySelector('.mini-day.has-tasks'),'::after').width==='4px'`,'年历圆点可见');
  await expectPage(`(() => {
    const cards=[...document.querySelectorAll('.mini-month')].map(card=>card.getBoundingClientRect());
    return cards[0].top===cards[1].top && cards[1].top<cards[2].top && cards[0].left===cards[2].left &&
      cards[0].width>250 && document.querySelector('.mini-day').getBoundingClientRect().height>=26 &&
      getComputedStyle(document.querySelector('.mini-day')).fontSize==='14px';
  })()`,'十二区月卡按两列排列且日期放大');
  const nextDay=await evaluate(`document.querySelector('.mini-day[aria-current=date]').nextElementSibling?.dataset.date ||
    document.querySelector('.mini-day[aria-current=date]').previousElementSibling?.dataset.date`);
  const selectedDay=nextDay||monthMarks.find(([,marked])=>marked)?.[0];
  await choose(`.mini-day[data-date="${selectedDay}"]`);
  await expectPage(`!!document.querySelector('.year-view .mini-day[data-date="${selectedDay}"][aria-pressed=true]') &&
    document.querySelector('.tasks-card h2').textContent.endsWith('${Number(selectedDay.slice(8))}日的任务')`,'点击年历具体日期，右侧切当天且保持年视图');
  await expectPage(`(() => {
    const grid=document.querySelector('#year-month-grid'), button=document.querySelector('.mini-day[aria-pressed=true]');
    return grid.scrollHeight>grid.clientHeight && button.getBoundingClientRect().bottom<=innerHeight &&
      document.querySelector('.calendar-header').getBoundingClientRect().top>=0;
  })()`,'年历在列内滚动并保证所选日期可见');
  await screenshot('calendar-year');
  await screenshot('calendar-year-wide',2560,1269);
  await expectPage(`document.querySelector('.calendar-card').getBoundingClientRect().width<=620 &&
    getComputedStyle(document.querySelector('.mini-day')).fontSize==='14px'`,'宽屏年历限宽而日期文字等比例放大');
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:930,deviceScaleFactor:1,mobile:false},sessionId);
  await choose('[data-act=calendar-year]');
  await set('#modal-form [name=year]','2028');
  await submit('#modal-form');
  await expectPage('!document.querySelector("#dialog").open && document.querySelector(".mini-month").getAttribute("aria-label")==="2028年1月"','直接跨年');
  await choose('[data-act=calendar-prev]');
  await expectPage('document.querySelector(".mini-month").getAttribute("aria-label")==="2027年1月"','上一年');
  await choose('[data-act=calendar-next]');
  await choose('.mini-day[data-date="2028-02-29"]');
  await expectPage(`!!document.querySelector('.year-view .mini-day[data-date="2028-02-29"][aria-pressed=true]')`,'年历选中闰日');
  await choose('[data-act=calendar-view][data-view=month]');
  await expectPage(`!!document.querySelector('[data-date="2028-02-29"]')`,'闰年月底');
  await choose('[data-act=calendar-view][data-view=year]');
  await choose('.mini-day[data-date="2028-12-31"]');
  await choose('[data-act=calendar-view][data-view=month]');
  await wheel('.calendar-days',-120);
  await expectPage(`!!document.querySelector('.calendar-day[data-date="2029-01-31"][aria-pressed=true]')`,'月历向上滚到下一月并跨年');
  await wheel('.calendar-days',120);
  await expectPage(`!!document.querySelector('.calendar-day[data-date="2028-12-31"][aria-pressed=true]')`,'月历向下滚到上一月并跨年');
  await wheel('.tasks-card',-120);
  await expectPage(`!!document.querySelector('.calendar-day[data-date="2028-12-31"][aria-pressed=true]')`,'任务区滚动保持月份');
  await choose('[data-act=today]');
  await expectPage('document.querySelectorAll(".task-row").length===2','点今天筛选任务');
  await goto('tasks');
  await expectPage('document.querySelectorAll(".task-row").length===6','恢复全部任务');
  await choose('[data-act=select][data-id="89-demo-0"]');
  await expectPage(content('.inspector','核对本周的三项重点'),'任务详情');
  await expectPage('document.querySelector(".inspector .file-chip img")?.naturalWidth===16','任务详情下载并解码缩略图');
  await choose('.inspector [data-act=edit]');
  await expectPage('document.querySelector("#dialog .file-chip img")?.naturalWidth===16','任务编辑下载并解码缩略图');
  await screenshot('attachment-editor');
  await set('#modal-form [name=remark]','保留未保存草稿');
  await choose('#dialog .file-chip');
  await expectPage('document.querySelector("#media-dialog").open && document.querySelector("#media-dialog img")?.naturalWidth===16','查看任务原图');
  await screenshot('attachment-preview');
  await choose('[data-act=close-media]');
  await expectPage('!document.querySelector("#media-dialog").open && document.querySelector("#dialog").open && document.querySelector("#modal-form [name=remark]").value==="保留未保存草稿"','关闭预览返回未保存编辑');
  await choose('#dialog .dialog-head [data-act=close]');
  await choose('[data-act=complete][data-id="89-demo-0"]');
  await expectPage(`!document.querySelector('[data-act=select][data-id="89-demo-0"]')`,'完成后从待完成象限移出');
  await choose('[data-filter=done]');
  await expectPage(content('.inspector .status-pill','已完成'),'任务勾选');
  await expectPage(`!!document.querySelector('[data-rank="2"] .task-row.completed')`,'已完成任务仍在原优先级象限');
  await choose('[data-act=complete][data-id="89-demo-0"]');
  await choose('[data-filter=open]');
  await expectPage(content('.inspector .status-pill','待完成'),'任务恢复');
  await choose('.page-actions [data-act=new]');
  await set('#modal-form [name=name]','浏览器新建任务');
  await submit('#modal-form');
  await expectPage(content('#quadrant-1','浏览器新建任务'),'保存任务');
  await expectPage('!document.querySelector("#dialog").open','关闭创建窗口');
  await choose('.inspector [data-act=delete]');
  await submit('#modal-form');
  await expectPage('!document.querySelector(".task-board").innerText.includes("浏览器新建任务")','软删除任务');
  await goto('trash');
  await expectPage(content('.trash-card','浏览器新建任务'),'回收站');
  await choose('[data-act=restore]');
  await expectPage('!document.querySelector(".trash-card").innerText.includes("浏览器新建任务")','恢复');

  await goto('bills');
  await expectPage('document.querySelectorAll(".ledger-table:not(.stats-table) tbody tr").length === 4','账单明细');
  await screenshot('ledger');
  await choose('[data-act=bill-filter][data-party="微信余额"][data-type=expense]');
  await expectPage('document.querySelectorAll(".ledger-table:not(.stats-table) tbody tr").length === 1','收支方过滤');
  await choose('[data-act=bill-filter][data-party="微信余额"][data-type=expense]');
  await expectPage('document.querySelectorAll(".ledger-table:not(.stats-table) tbody tr").length === 4','取消过滤');
  await choose('.page-actions [data-act=new]');
  await set('#modal-form [name=name]','精确金额测试');
  await set('#modal-form [name=amount]','12.037');
  await submit('#modal-form');
  await expectPage(content('.inspector','12.037'),'精确金额保存');

  await goto('notes');
  await choose('[data-act=select][data-id="49-demo-0"]');
  await expectPage(content('#note-messages','咖啡店'),'打开速记');
  await set('#note-send textarea','发送立即保存');
  await submit('#note-send');
  await expectPage(content('#note-messages','发送立即保存'),'本地即时保存');
  await evaluate(`(() => {
    const control=document.querySelector('#note-files'), file=new File([Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jvZkAAAAASUVORK5CYII='),c=>c.charCodeAt(0))],'sample.png',{type:'image/png'});
    const data=new DataTransfer();data.items.add(file);control.files=data.files;control.dispatchEvent(new Event('change',{bubbles:true}));
  })()`);
  await expectPage('!!document.querySelector("#note-messages img")','图片上传本地预览');
  await screenshot('notes');
  await choose('[data-act=note-section][data-section=essence]');
  await choose('[data-act=select][data-id="49-demo-1"]');
  await expectPage(content('.document-body','复盘时先区分'),'精髓文档');
  await choose('.note-head [data-act=edit]');
  await expectPage('!!document.querySelector(".note-content #note-edit-form textarea") && !document.querySelector("#dialog").open','精髓原地编辑');
  await set('#note-edit-form textarea','正文现在直接在页面中编辑');
  await choose('[data-act=sync]');
  await expectPage(`document.querySelector('#note-edit-form textarea')?.value==='正文现在直接在页面中编辑'`,'同步时保留编辑草稿');
  await submit('#note-edit-form');
  await expectPage(content('.document-body','正文现在直接在页面中编辑'),'原地编辑保存');
  await choose('[data-act=note-section][data-section=diary]');
  for (const title of ['生活','旅行','随笔']) {
    await choose('[data-act=folder-new]');
    await set('#folder-form [name=name]',title);
    await submit('#folder-form');
    await expectPage(`!document.querySelector('#folder-form')&&document.querySelector('.folder-choice[aria-pressed=true]').textContent.includes('${title}')`,'依次建立三层目录');
  }
  await choose('[data-act=folder-new]');
  await expectPage(`![...document.querySelectorAll('#folder-form select option')].some(option=>option.textContent==='生活 / 旅行 / 随笔')`,'三级目录不可作为上级目录');
  await choose('[data-act=folder-cancel]');
  await choose('.page-actions [data-act=new]');
  await expectPage(`document.querySelector('#note-edit-form [name=parent]').selectedOptions[0].textContent==='生活 / 旅行 / 随笔'`,'新日记选中当前目录');
  await set('#note-edit-form [name=name]','小路记录');
  await set('#note-edit-form textarea','日记原地写作');
  await evaluate(`(() => {
    const field=document.querySelector('#document-images'), transfer=new DataTransfer();
    const payload='iVBORw0KGgoAAAANSUhEUgAAABAAAAAKCAIAAAAy3EnLAAAAGklEQVR4nGNM9D/MQApgIkk1w6gG4gDtgxUA2AIBh2gVloUAAAAASUVORK5CYII=';
    transfer.items.add(new File([Uint8Array.from(atob(payload),ch=>ch.charCodeAt(0))],'日记图片.png',{type:'image/png'}));
    field.files=transfer.files;
    field.dispatchEvent(new Event('change',{bubbles:true}));
  })()`);
  await submit('#note-edit-form');
  await expectPage(content('.document-body','日记原地写作'),'日记正文保存');
  await expectPage(`document.querySelector('.document-body img')?.naturalWidth===16`,'日记内联插图显示');
  await expectPage(`document.querySelector('.note-tile.selected strong').textContent==='小路记录'`,'自定义名称不加日期');
  await screenshot('diary');
  await choose('[data-act=note-section][data-section=info]');
  await expectPage(`!document.querySelector('.notes-list').textContent.includes('小路记录')`,'日记目录和信息独立');
  await choose('.page-actions [data-act=new]');
  await set('#note-edit-form [name=name]','参考资料');
  await set('#note-edit-form textarea','信息记录内容');
  await submit('#note-edit-form');
  await expectPage(content('.document-body','信息记录内容'),'信息文档支持同一编辑形式');
  await choose('[data-act=note-section][data-section=diary]');
  await choose('.note-tile[data-act=select]');
  await choose('.note-head [data-act=edit]');
  await screenshot('note-inline-edit');
  await choose('[data-act=note-edit-cancel]');

  await goto('ai');
  await set('#ai-send textarea','汇总本月支出');
  await submit('#ai-send');
  await expectPage(content('.markdown strong','已核对记录'),'AI Markdown 回答');
  await expectPage('!!document.querySelector(".markdown table")','Markdown 表格');
  await screenshot('ai');
  await goto('tasks');
  await screenshot('mobile',390,844);
  assert.equal(await evaluate('document.documentElement.scrollWidth===document.documentElement.clientWidth'),true);
  await choose('[data-act=select][data-id="89-demo-0"]');
  assert.equal(await evaluate('document.documentElement.scrollWidth===document.documentElement.clientWidth'),true);
  await expectPage(content('.inspector','整理本周的工作计划'),'窄屏详情');
  await call('Page.reload',{},sessionId);
  await expectPage(content('#quadrant-1','浏览器新建任务'),'刷新后恢复扫码会话和本机数据');
  await expectPage('document.querySelector("#sync-status").textContent === "已同步"','后台同步完成');
  assert.ok([...backend.records.values()].some(row=>row.data.name==='精确金额测试'&&row.data.amount==='12.037'));
  assert.ok([...backend.records.values()].some(row=>row.data.content==='发送立即保存'));
  assert.ok([...backend.records.values()].some(row=>row.data.media_id));
  assert.ok([...backend.records.values()].some(row=>row.data.title==='小路记录'&&row.data.notebook_section.startsWith('diary:doc:')));
  assert.ok([...backend.records.values()].some(row=>row.data.title==='参考资料'&&row.data.notebook_section==='info'));
  const baseDate=new Date();
  baseDate.setHours(10,0,0,0);
  for (const [index,title] of ['检查资料附件','准备周末采购','核对已完成事项','预订会议室','整理项目文档',
    '更新本周计划','备份工作文件','核对报销单','预约设备维护','整理待办清单','更新资料索引','归档会议纪要',
    '完成本月复盘','查看下周安排','归档参考资料','确认交付清单'].entries()) {
    const uid='89-wide-'+index;
    const at=baseDate.getTime()/1000+index*60;
    backend.seed(T.task,uid,{name:title,rank:index%4+1,privacy:6720});
    backend.seed(T.schedule,'79-wide-'+index,{task_id:uid,start_at:at,end_at:at+3600,is_all_day:0});
    if(index>=10)backend.seed(T.check,'76-wide-'+index,{task_id:uid,start_at:at,check_at:at+600,status:1});
  }
  await choose('[data-act=sync]');
  await expectPage('document.querySelectorAll(".task-row").length===17 && !document.querySelector(".task-row.completed")','同步后默认仅显示待完成');
  await call('Emulation.setDeviceMetricsOverride',{width:2560,height:1269,deviceScaleFactor:1,mobile:false},sessionId);
  await choose('[data-act=select][data-id="89-demo-0"]');
  await expectPage(`(() => {
    const [first,second,third,fourth]=Array.from(document.querySelectorAll('.task-quadrant'), node=>node.getBoundingClientRect());
    const detail=document.querySelector('.inspector').getBoundingClientRect();
    return first.top===second.top && third.top===fourth.top && first.left===third.left &&
      second.left===fourth.left && first.top<third.top && first.right<second.left && second.right<detail.left;
  })()`,'宽屏四象限和详情保持并列');
  await screenshot('tasks-wide',2560,1269);
  await goto('timeline');
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:680,deviceScaleFactor:1,mobile:false},sessionId);
  await expectPage('document.querySelectorAll(".task-row").length===18','时间轴按日读取含已完成的任务');
  await evaluate('window.scrollTo(0,300)');
  await expectPage('scrollY>=200&&document.querySelector(".calendar-card").getBoundingClientRect().top===14&&document.querySelector(".task-list-heading").getBoundingClientRect().top===0','长列表滚动时固定日历与筛选栏');
  await choose('[data-act=calendar-view][data-view=year]');
  await choose('[data-act=calendar-year]');
  await set('#modal-form [name=year]','2028');
  await submit('#modal-form');
  await expectPage(`!document.querySelector('#dialog').open && !!document.querySelector('.mini-day[data-date="2028-02-29"]:not(.has-tasks)')`,'跨年后闰日初始无任务');
  const leap=new Date(2028,1,29,9).getTime()/1000;
  backend.seed(T.task,'89-year-marks',{name:'闰日重复任务',rank:1,privacy:6720});
  backend.seed(T.schedule,'79-year-marks',{task_id:'89-year-marks',start_at:leap,end_at:leap+3600,is_all_day:0});
  backend.seed(T.repeat,'78-year-marks',{task_id:'89-year-marks',schedule_id:'79-year-marks',
    repeat_start_day:leap,day_interval:86400,repeat_count:2});
  await choose('[data-act=sync]');
  await expectPage(`!!document.querySelector('.mini-day.has-tasks[data-date="2028-02-29"]') &&
    !!document.querySelector('.mini-day.has-tasks[data-date="2028-03-01"]') &&
    !!document.querySelector('.mini-day[data-date="2028-03-02"]:not(.has-tasks)')`,'年历同步后显示闰日及重复任务圆点');
  await choose('.mini-day[data-date="2028-02-29"]');
  await expectPage(`!!document.querySelector('.year-view')&&document.querySelectorAll('.task-row').length===1&&
    document.querySelector('.task-row').textContent.includes('闰日重复任务')`,'年历点击有任务的日子时显示指定任务');
  await choose('[data-act=calendar-next]');
  await expectPage(`!!document.querySelector('.mini-day[data-date="2029-03-01"]') && !document.querySelector('.mini-day.has-tasks')`,'切换年份后清除旧年份标记');
  assert.deepEqual(errors,[]);
  console.log('Chromium 通过两列年历、点日和滚动、四象限、日记信息、三层目录、正文原地编辑及内联图片验收。');
} finally {
  browser.kill();
  gateway.close();
  backend.server.close();
}
