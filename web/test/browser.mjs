import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createWebServer } from '../server.mjs';
import { fixture, listen } from './fixture.mjs';

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
  await expectPage(content('.task-list','整理本周的工作计划'),'任务同步');
  await expectPage('document.querySelector(".calendar-card").getBoundingClientRect().right < document.querySelector(".tasks-card").getBoundingClientRect().left','日历左、任务列表右');
  await screenshot('tasks');
  await choose('[data-act=calendar-view][data-view=year]');
  await expectPage('document.querySelectorAll(".mini-month").length===12','年视图 12 个月');
  await screenshot('calendar-year');
  await choose('[data-act=calendar-year]');
  await set('#modal-form [name=year]','2028');
  await submit('#modal-form');
  await expectPage('!document.querySelector("#dialog").open && document.querySelector(".mini-month").getAttribute("aria-label")==="2028年1月"','直接跨年');
  await choose('[data-act=calendar-prev]');
  await expectPage('document.querySelector(".mini-month").getAttribute("aria-label")==="2027年1月"','上一年');
  await choose('[data-act=calendar-next]');
  await choose('[data-act=calendar-month][data-month="1"]');
  await expectPage(`!!document.querySelector('[data-date="2028-02-29"]')`,'闰年月底');
  await choose('[data-act=calendar-view][data-view=year]');
  await choose('[data-act=calendar-month][data-month="11"]');
  await choose('[data-act=calendar-next]');
  await expectPage(`!!document.querySelector('[data-date="2029-01-31"]')`,'十二月至次年一月');
  await choose('[data-act=today]');
  await expectPage('document.querySelectorAll(".task-row").length===2','点今天筛选任务');
  await choose('[data-act=clear-day]');
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
  await expectPage(content('.inspector .status-pill','已完成'),'任务勾选');
  await choose('[data-act=complete][data-id="89-demo-0"]');
  await expectPage(content('.inspector .status-pill','待完成'),'任务恢复');
  await choose('.page-actions [data-act=new]');
  await set('#modal-form [name=name]','浏览器新建任务');
  await submit('#modal-form');
  await expectPage(content('.task-list','浏览器新建任务'),'保存任务');
  await expectPage('!document.querySelector("#dialog").open','关闭创建窗口');
  await choose('.inspector [data-act=delete]');
  await submit('#modal-form');
  await expectPage('!document.querySelector("[data-act=select][data-id^=\'89-\']") || !document.querySelector(".task-list").innerText.includes("浏览器新建任务")','软删除任务');
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
  await expectPage(content('.task-list','浏览器新建任务'),'刷新后恢复扫码会话和本机数据');
  await expectPage('document.querySelector("#sync-status").textContent === "已同步"','后台同步完成');
  assert.ok([...backend.records.values()].some(row=>row.data.name==='精确金额测试'&&row.data.amount==='12.037'));
  assert.ok([...backend.records.values()].some(row=>row.data.content==='发送立即保存'));
  assert.ok([...backend.records.values()].some(row=>row.data.media_id));
  assert.deepEqual(errors,[]);
  console.log('Chromium 通过月历与跨年、任务原图及草稿保留、扫码、任务、回收站、账单、便签和 AI 验收。');
} finally {
  browser.kill();
  gateway.close();
  backend.server.close();
}
