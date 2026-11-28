import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { createWebServer } from '../server.mjs';
import { fixture, listen } from './fixture.mjs';
import { T, amount, decimal, applyPage, get, put, saveTask, taskViews, taskSnapshot, toggleTask, restoreTaskChecks } from '../public/domain.mjs';
import { markdown } from '../public/view.mjs';

test('扫码会话由网页代理持有，同源请求可同步并读取附件', async t=>{
  const upstream=fixture();
  const origin=await listen(upstream.server);
  t.after(()=>upstream.server.close());
  const web=createWebServer({upstream:origin});
  const url=await listen(web);
  t.after(()=>web.close());
  const post=(route,data={},cookie='',from=url)=>fetch(url+'/api/'+route,{method:'POST',
    headers:{origin:from,cookie,...(data instanceof FormData?{}:{'Content-Type':'application/json'})},
    body:data instanceof FormData?data:JSON.stringify(data)});
  assert.equal((await post('sync')).status,401);
  assert.equal((await post('login',{},'', 'https://foreign.example')).status,403);
  const login=await post('login');
  const query=await login.json();
  assert.equal(query.code,'834621');
  assert.ok(query.qr.startsWith('gxtodo://desktop-login?'));
  assert.equal(query.verifier,undefined);
  const grant=login.headers.getSetCookie()[0].split(';')[0];
  assert.deepEqual(await (await post('login/poll',{},grant)).json(),{account:null});
  upstream.approve();
  assert.equal((await post('login/poll')).status,422);
  const sessionResponse=await post('login/poll',{},grant);
  const cookies=sessionResponse.headers.getSetCookie();
  assert.match(cookies[0],/HttpOnly; SameSite=Strict/);
  const session=cookies[0].split(';')[0];
  assert.equal((await sessionResponse.json()).account.id,42);
  const pull=await post('sync',{user_id:97,token:'client-supplied',_data:[],entropy:{}},session);
  assert.equal(pull.status,200);
  assert.ok((await pull.json()).down.some(row=>row.table_id===T.task));
  const file=new FormData();
  const content=Buffer.from('attachment fixture');
  for(const [name,value] of Object.entries({team_id:71,note_id:'49-demo-0',parent_table:49,kind:'image',
    client_id:'fixture-media-v1',sha256:createHash('sha256').update(content).digest('hex')}))file.set(name,value);
  file.set('file',new Blob([content],{type:'image/png'}),'test.png');
  const {data:{id}}=await (await post('files/upload',file,session)).json();
  const download=await post('files/read',{id},session);
  assert.equal(download.headers.get('content-type'),'application/octet-stream');
  assert.deepEqual(Buffer.from(await download.arrayBuffer()),content);
  assert.equal((await post('logout',{},session)).status,200);
  assert.equal((await post('teams',{},session)).status,401);
});

test('同步回执保留发送后的编辑，服务器重置游标后继续分页',()=>{
  const state={rows:{},cursors:{t71:99},spaces:[{id:71}]};
  const first=put(state,42,71,T.bill,'51-local',{name:'本地金额',amount:'0.1'});
  put(state,42,71,T.bill,'51-local',{name:'在网络返回之前继续修改'});
  applyPage(state,[first],{ data:[{uid:first.uid,status:0,entropy:7}],down:[],
    down_extra:[{team_id:71,entropy:7,remain:1}] });
  assert.equal(state.cursors.t71,7);
  const latest=get(state,71,T.bill,'51-local');
  assert.equal(latest.pending,2);
  assert.equal(latest.data.name,'在网络返回之前继续修改');
  assert.equal(decimal(amount('999999999999999999999999999999.11')+amount('0.009')),'999999999999999999999999999999.119');
});

test('重复规则、日期和 Markdown 保持可用',()=>{
  const state={rows:{},cursors:{},spaces:[{id:71,type:1}]};
  const start=new Date(2026,10,27,9).getTime()/1000;
  const row=saveTask(state,42,71,'89-repeat',{name:'每日计划',rank:1,start,end:start+3600,repeat:1,alert:0,children:['准备'],tags:['计划']},71);
  assert.equal(taskViews(state,71,42)[0].at(new Date(2026,10,28)),new Date(2026,10,28,9).getTime()/1000);
  toggleTask(state,42,row,start);
  const saved=taskSnapshot(state,row,42);
  assert.equal(saved.checks[0][0],start);
  assert.deepEqual(saved.completedChildren,[]);
  assert.deepEqual(saved.tags,['计划']);
  assert.equal(taskViews(state,71,42)[0].next(new Date(2026,10,27)),start);
  toggleTask(state,42,row,start);
  restoreTaskChecks(state,42,row,saved);
  assert.ok(taskViews(state,71,42)[0].done(start));
  const html=markdown('## 标题\n\n**金额** <script>alert(1)</script>\n\n| 项目 | 金额 |\n| --- | --- |\n| 午餐 | 46.80 |');
  assert.match(html,/<h4>标题<\/h4>/);
  assert.match(html,/<table>/);
  assert.doesNotMatch(html,/<script>/);
  assert.match(html,/&lt;script&gt;/);
});

test('便签 Markdown 能展示链接和引用，原样转义 HTML 与危险链接',()=>{
  const html=markdown('## 标题\n\n> 引用\n\n`**代码**` [资料](https://example.com/?a=1&b=2) [坏链接](javascript:alert) <img src=x onerror=alert(1)>');
  assert.match(html,/<h4>标题<\/h4>/);
  assert.match(html,/<blockquote><p>引用<\/p><\/blockquote>/);
  assert.match(html,/<code>\*\*代码\*\*<\/code>/);
  assert.match(html,/href="https:\/\/example.com\/\?a=1&amp;b=2"/);
  assert.doesNotMatch(html,/href="javascript:|<img/);
  assert.match(html,/&lt;img/);
});
