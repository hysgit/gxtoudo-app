import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { T, addDays, dateKey, stamp } from '../public/domain.mjs';

export const listen = server => new Promise((resolve,reject)=>{
  server.once('error',reject);
  server.listen(0,'127.0.0.1',()=>resolve('http://127.0.0.1:'+server.address().port));
});

export function fixture({ autoApprove=false }={}) {
  const spaces=[{id:71,name:'个人空间',type:1},{id:72,name:'工作小组',type:2}];
  const records=new Map(), grants=new Map(), turns=new Map(), uploads=new Map();
  let revision=0;
  const seed = (table,uid,data) => {
    const time=String(data.created_at||stamp(Date.now()));
    records.set(uid,{table_id:table,edit_mode:1,sync_entropy:++revision,data:{
      uid,team_id:71,user_id:42,created_at:time,updated_at:time,...data}});
  };
  const now=new Date();
  const tasks=[
    ['整理本周的工作计划',0,9,2],['确认项目交付时间',0,14,3],['更新设计资料库',1,10,2],
    ['阅读本月账单',1,19,1],['备份相册原图',2,20,1],['准备周会记录',3,9,2],
  ];
  for (const [index,[name,delta,hour,rank]] of tasks.entries()) {
    const day=addDays(now,delta);day.setHours(hour,0,0,0);
    const start_at=day.getTime()/1000;
    seed(T.task,'89-demo-'+index,{name,rank,privacy:6720});
    seed(T.schedule,'79-demo-'+index,{task_id:'89-demo-'+index,start_at,end_at:start_at+3600,is_all_day:0});
  }
  seed(T.detail,'86-demo-0',{task_id:'89-demo-0',type:2,content:'核对本周的三项重点，确认各项任务的交付日期。'});
  seed(T.subtask,'87-demo-0',{task_id:'89-demo-0',sequence:0,name:'回顾上周未完成事项'});
  seed(T.subtask,'87-demo-1',{task_id:'89-demo-0',sequence:1,name:'整理本周优先级'});
  const preview=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAABAAAAAKCAIAAAAy3EnLAAAAGklEQVR4nGNM9D/MQApgIkk1w6gG4gDtgxUA2AIBh2gVloUAAAAASUVORK5CYII=','base64');
  uploads.set('task-picture',new Blob([preview],{type:'application/octet-stream'}));
  seed(T.taskFile,'54-demo-image',{note_id:'89-demo-0',parent_table:T.task,kind:'image',media_id:'task-picture',
    media_name:'任务图片.png',content_type:'application/octet-stream',size:preview.length,
    sha256:createHash('sha256').update(preview).digest('hex')});
  const month=dateKey(now).slice(0,7);
  for (const [index,[name,type,amount,channel,party]] of [
    ['工作日午餐','expense','46.80','微信','微信余额'],
    ['周末书单','expense','128.50','支付宝','支付宝余额'],
    ['项目报销','income','638.40','微信','微信余额'],
    ['通勤交通','expense','28.00','银联云闪付','工行卡'],
  ].entries()) seed(T.bill,'51-demo-'+index,{name,date:month+'-'+String(index+1).padStart(2,'0'),type,amount,channel,party,currency:'CNY'});
  seed(T.note,'49-demo-0',{name:'周末计划',title:'周末计划',conversation_version:1,attachments:'[]'});
  seed(T.entry,'50-demo-0',{note_id:'49-demo-0',kind:'text',content:'找一家安静的咖啡店，把下周读书清单整理出来。',entry_at:Date.now()});
  seed(T.note,'49-demo-1',{name:'读书摘录',title:'读书摘录',conversation_version:1,notebook_section:'essence',attachments:'[]'});
  seed(T.entry,'50-demo-1',{note_id:'49-demo-1',kind:'text',content:'复盘时先区分已经验证的结论和下一步的假设。',entry_at:Date.now()});

  const server=createServer(async(req,res)=>{
    try {
      const chunks=[];
      for await (const part of req) chunks.push(part);
      const body=Buffer.concat(chunks);
      const path=req.url.slice('/api/v7'.length);
      const form=path==='/media/upload'?await new Response(body,{headers:{'Content-Type':req.headers['content-type']}}).formData():null;
      const value=form?Object.fromEntries(form):JSON.parse(body);
      const send = data => {res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({status:'0',...data}));};
      if (path==='/desktop-login/start') {
        const key='grant-'+grants.size;
        grants.set(key,{challenge:value.challenge,approved:autoApprove});
        send({request:key,code:'834621',valid_seconds:120});return;
      }
      if (path==='/desktop-login/poll') {
        const grant=grants.get(value.request);
        if (!grant || createHash('sha256').update(value.verifier).digest('hex')!==grant.challenge) {
          send({status:'410',message:'验证码失效'});return;
        }
        if (!grant.approved) {send({state:'waiting'});return;}
        grants.delete(value.request);
        send({state:'complete',user_id:42,login_id:27,token:'fixture-token',data:{nickname:'林同学'},teamData:spaces});return;
      }
      if (Number(value.user_id)!==42||Number(value.login_id)!==27||value.token!=='fixture-token') {
        send({status:'5',message:'登录失效'});return;
      }
      if (path==='/team/list') {send({data:spaces});return;}
      if (path==='/sync/do') {
        const accepted=[];
        for (const row of value._data) {
          const data=row.mode===3?{...records.get(row.data.uid)?.data,...row.data}:row.data;
          const update={table_id:row.table,edit_mode:row.mode===4?2:row.mode,sync_entropy:++revision,data};
          records.set(data.uid,update);
          accepted.push({uid:data.uid,status:0,entropy:revision});
        }
        const down=[...records.values()].filter(row=>row.sync_entropy>(value.entropy['t'+row.data.team_id]||0));
        send({data:accepted,down,down_extra:spaces.map(space=>({team_id:space.id,entropy:revision,remain:0}))});
        return;
      }
      if (path==='/ai/chat'&&value._method==='POST') {
        const turn={id:1,question:value.question,state:'done',answer:'### 记录汇总\n\n**已核对记录**\n\n| 类型 | 金额 |\n| --- | --- |\n| 支出 | 46.80 元 |',thread:value.thread};
        turns.set(value.thread,[...(turns.get(value.thread)||[]),turn]);
        send({id:1});return;
      }
      if (path==='/ai/chat') {
        send({ data:value.thread ? turns.get(value.thread)||[] : [...turns.values()].map(turns=>turns.at(-1)) });return;
      }
      if (path==='/media/upload') {
        const file=form.get('file'), checksum=createHash('sha256').update(Buffer.from(await file.arrayBuffer())).digest('hex');
        if (checksum!==value.sha256) {send({status:'1',message:'校验失败'});return;}
        const id='file-'+uploads.size;
        uploads.set(id,file);
        send({data:{id,content_type:file.type,size:file.size,sha256:checksum}});return;
      }
      if (path==='/media/read'&&uploads.has(value.id)) {
        const file=uploads.get(value.id);
        res.writeHead(200,{'Content-Type':file.type});
        res.end(Buffer.from(await file.arrayBuffer()));return;
      }
      if (path==='/user/session') {send({});return;}
      send({status:'1',message:'未实现测试接口'});
    } catch {
      res.writeHead(500);res.end();
    }
  });
  return { server, records, approve(){for(const grant of grants.values())grant.approved=true;} };
}
