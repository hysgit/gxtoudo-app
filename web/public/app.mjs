import { QrCode } from './qrcodegen.mjs';
import { icon } from './icons.mjs';
import { action, attachmentRow, h, pages, shell, signin } from './view.mjs';
import { Workspace, addFiles, digest, request, stageFiles } from './api.mjs';
import { T, addDays, dateKey, clock, whenText, billTypes, priorities, repeatNames, reminders,
  get, list, id, put, remove, noteEntries, noteTitle, noteParent, noteFolders, customNotebook, documentSection, saveNoteFolder,
  filesOf, saveTask, taskSnapshot,
  toggleTask, restoreTaskChecks, saveBill, billSnapshot, versions, captureVersion } from './domain.mjs';

const app=document.querySelector('#app'), dialog=document.querySelector('#dialog'), mediaDialog=document.querySelector('#media-dialog');
const today=()=>dateKey(new Date());
const SpeechRecognition=window.SpeechRecognition||window.webkitSpeechRecognition;
const initialPage=pageFromHash();
const defaultFilter=page=>page==='tasks'?'open':'all';
const ctx={
  account:null, state:null, page:initialPage, team:0, selected:null, query:'',
  calendarDate:new Date(), calendarView:'month', day:null, filter:defaultFilter(initialPage), month:today().slice(0,7), billFilter:null, archive:false,
  noteSection:'quick', noteDraft:'', recording:false, canDictate:!!SpeechRecognition,
  noteFolder:'', folderDraft:null, noteEdit:null,
  ai:{ conversations:[], turns:[], thread:'', draft:'', file:null },
  status:'正在同步', syncFailed:false,
};
let workspace, qrController, qrTimer, syncTimer, toastTimer, aiTimer, formHandler;
let noteRecorder, previewObserver, dialogPreviewObserver, editorRecord;
let login={ loading:true, message:'正在获取登录二维码…' };
let composing=false;
const media=new Map();
const noteEdits=new Map();
let modalURL, mediaJob=0;

function pageFromHash() {
  const value=location.hash.slice(1);
  return Object.hasOwn(pages,value)?value:'tasks';
}
function notify(message) {
  const toast=document.querySelector('#toast');
  toast.textContent=message;
  clearTimeout(toastTimer);
  toastTimer=setTimeout(()=>{toast.textContent='';},4200);
}
function status(message,failed=false) {
  ctx.status=message;
  ctx.syncFailed=failed;
  const label=document.querySelector('#sync-status');
  if (label) label.textContent=message;
  document.querySelector('.sync-dot')?.classList.toggle('sync-error',failed);
}
function render({ bottom=false }={}) {
  if (composing) return;
  const active=document.activeElement;
  const field=active?.matches('#search,#note-send textarea,#ai-send textarea') ? active.closest('form')?.id : null;
  const search=active?.id==='search';
  const draftField=active?.name && active.closest('#note-edit-form,#folder-form')
    ? [active.form.id,active.name,active.scrollTop] : null;
  const selection=active instanceof HTMLInputElement||active instanceof HTMLTextAreaElement
    ? [active.selectionStart,active.selectionEnd] : null;
  const navKey=active instanceof HTMLElement && app.contains(active) && active.matches(':focus-visible')
    ? { ...active.dataset } : null;
  const scrollIds=['note-messages','ai-turns','year-month-grid','quadrant-1','quadrant-2','quadrant-3','quadrant-4'];
  const previousScroll=Object.fromEntries(scrollIds.map(id=>[id,document.getElementById(id)?.scrollTop||0]));
  const collapsed=[...app.querySelectorAll('details:not([open]) > summary')].map(node=>node.textContent);
  app.innerHTML=ctx.account&&ctx.state?shell(ctx):signin(login);
  for (const summary of app.querySelectorAll('details > summary')) {
    if (collapsed.includes(summary.textContent)) summary.parentElement.open=false;
  }
  app.setAttribute('aria-busy',String(!ctx.account&&login.loading));
  if (ctx.account&&ctx.state) {
    for (const id of scrollIds) {
      const node=document.getElementById(id);
      if (node) node.scrollTop=bottom?node.scrollHeight:previousScroll[id];
    }
    if (search||field||draftField) {
      const next=draftField?document.getElementById(draftField[0])?.elements.namedItem(draftField[1]):
        search?document.querySelector('#search'):document.querySelector('#'+field+' textarea');
      next?.focus({ preventScroll:true });
      if (next && selection && selection[0]!==null) next.setSelectionRange(...selection);
      if (next && draftField) next.scrollTop=draftField[2];
    } else if (navKey?.act) {
      [...app.querySelectorAll('[data-act]')].find(node=>Object.entries(navKey).every(([key,value])=>node.dataset[key]===value))
        ?.focus({ preventScroll:true });
    }
    schedulePreviews();
  } else if (login.qr) paintQR(login.qr);
}

function paintQR(value) {
  const qr=QrCode.encodeText(value,QrCode.Ecc.MEDIUM);
  const canvas=document.querySelector('#qr'), side=(qr.size+8)*5;
  canvas.width=canvas.height=side;
  const dc=canvas.getContext('2d');
  dc.fillStyle='#fff';dc.fillRect(0,0,side,side);
  dc.fillStyle='#161428';
  for (let y=0;y<qr.size;y++) for (let x=0;x<qr.size;x++) {
    if (qr.getModule(x,y)) dc.fillRect((x+4)*5,(y+4)*5,5,5);
  }
}

function stopLogin() {
  clearTimeout(qrTimer);
  qrController?.abort();
  qrController=null;
}

async function startLogin() {
  stopLogin();
  const controller=qrController=new AbortController();
  const {signal}=controller;
  login={ loading:true, message:'正在获取登录二维码…' };
  render();
  try {
    const data=await request('login',{},signal);
    if (signal.aborted) return;
    const expires=Date.now()+data.duration*1000;
    login={ ...data, loading:false, message:'扫码后，请核对手机上的数字。' };
    render();
    const poll=async()=>{
      if (signal.aborted) return;
      if (Date.now()>=expires) {
        login={ loading:false, message:'二维码已过期，点击刷新后再扫码。' };
        render();
        return;
      }
      try {
        const result=await request('login/poll',{},signal);
        if (!signal.aborted&&result.account) { await signIn(result.account); return; }
      } catch (error) {
        if (signal.aborted) return;
        if (error.code==='410') {
          login={loading:false,message:error.message};
          render();return;
        }
        const label=document.querySelector('.login-status');
        if (label) label.textContent='连接暂时中断，正在重试。';
      }
      if (!signal.aborted) qrTimer=setTimeout(poll,2100);
    };
    qrTimer=setTimeout(poll,1500);
  } catch (error) {
    if (signal.aborted) return;
    login={ loading:false, message:error.message };
    render();
  }
}

async function signIn(account) {
  stopLogin();
  ctx.account=account;
  ctx.team=Number(account.personal);
  status('正在同步');
  const local=workspace=new Workspace(account,()=>{
    if (workspace!==local) return;
    ctx.state=local.state;
    if (!ctx.state.spaces.some(space=>Number(space.id)===ctx.team)) ctx.team=account.personal;
    render();
  });
  await local.initialize();
  clearInterval(syncTimer);
  syncTimer=setInterval(sync,35_000);
  void sync();
  if (ctx.page==='ai') void loadConversations(true);
}

async function forgetAccount() {
  clearInterval(syncTimer);
  clearTimeout(aiTimer);
  workspace?.stop();
  workspace=null;
  if (noteRecorder?.state==='recording') noteRecorder.stop();
  previewObserver?.disconnect();
  dialogPreviewObserver?.disconnect();
  for (const value of media.values()) if (value.url) URL.revokeObjectURL(value.url);
  media.clear();
  noteEdits.clear();
  if (mediaDialog.open) mediaDialog.close();
  if (dialog.open) dialog.close();
  Object.assign(ctx,{ account:null, state:null, selected:null, query:'', noteDraft:'', noteFolder:'', folderDraft:null, noteEdit:null, recording:false,
    ai:{ conversations:[], turns:[], thread:'', draft:'', file:null } });
  await startLogin();
}

async function sync() {
  if (!workspace || workspace.busy) return;
  const local=workspace;
  status('正在同步');
  try {
    await local.sync();
    if (workspace===local) status('已同步');
  } catch (error) {
    if (workspace!==local) return;
    if (error.status===401) {
      notify('登录已失效，本机尚未同步的改动会保留');
      void forgetAccount();
    } else status(navigator.onLine?'等待重试':'离线 · 本机已保存',true);
  }
}

async function edit(action, files, { bottom=false }={}) {
  await workspace.edit(action,files);
  status('本机已保存');
  if (bottom) render({ bottom:true });
  setTimeout(sync,200);
}

const tableFor=()=>ctx.page==='notes'?T.note:ctx.page==='bills'?T.bill:T.task;
const record=(uid=ctx.selected,table=tableFor())=>get(ctx.state,ctx.team,table,uid);
const whenLocal=seconds=>seconds?dateKey(new Date(seconds*1000))+'T'+clock(new Date(seconds*1000)):'';
const options=(pairs,selected)=>pairs.map(([value,label])=>`<option value="${h(value)}" ${String(value)===String(selected)?'selected':''}>${h(label)}</option>`).join('');
const field=(label,input,wide=false)=>`<label class="field ${wide?'span':''}"><span>${label}</span>${input}</label>`;
const input=(name,value='',extra='')=>`<input name="${name}" value="${h(value)}" ${extra}>`;
const textarea=(name,value='',rows=3,extra='')=>`<textarea name="${name}" rows="${rows}" ${extra}>${h(value)}</textarea>`;
const select=(name,values,selected)=>`<select name="${name}">${options(values,selected)}</select>`;
const check=(name,label,value)=>`<label class="field-check"><input type="checkbox" name="${name}" ${value?'checked':''}>${label}</label>`;
const splitLines=value=>String(value||'').split('\n').map(line=>line.trim()).filter(Boolean);

function openDialog(title,body,handler=null,submitLabel='保存') {
  editorRecord=null;
  dialogPreviewObserver?.disconnect();
  formHandler=handler;
  dialog.innerHTML=`<div class="dialog-head"><h2 id="dialog-title">${h(title)}</h2>
    <button class="icon-button" type="button" data-act="close" aria-label="关闭">${icon('close',18)}</button></div>
    ${handler?`<form id="modal-form"><div class="dialog-body">${body}</div><div class="error-text" role="alert"></div>
    <div class="modal-actions">${action('取消','close',null)}<button type="submit" class="button primary">${h(submitLabel)}</button></div></form>`:
    `<div class="dialog-body">${body}</div>`}`;
  dialog.setAttribute('aria-labelledby','dialog-title');
  if (!dialog.open) dialog.showModal();
}

function editor(existing,rank=1) {
  const table=existing?.table||tableFor();
  if (table===T.note) { openNoteEditor(existing); return; }
  const team=ctx.team, account=ctx.account, uid=existing?.uid||id(table);
  const title=table===T.bill?'账单':'任务';
  let current, body;
  if (table===T.task) {
    current=existing?taskSnapshot(ctx.state,existing,account.id):{ rank, alert:0, reminderMode:'both',repeat:0 };
    const attachments=existing?filesOf(ctx.state,existing):[];
    body=`<div class="form-grid">
      ${field('任务名称',input('name',current.name,'maxlength="500" required autofocus'),true)}
      ${field('开始',input('start',current.start?whenLocal(current.start):ctx.day?ctx.day+'T09:00':'','type="datetime-local"'))}
      ${field('结束',input('end',whenLocal(current.end),'type="datetime-local"'))}
      ${check('allDay','全天',current.allDay)}
      ${field('优先级',select('rank',priorities.map((label,i)=>[i+1,label]),current.rank))}
      ${field('提醒',select('alert',reminders,current.alert))}
      ${field('提醒方式',select('reminderMode',[['both','闹钟和系统推送'],['alarm','闹钟'],['notification','系统推送']], current.reminderMode))}
      ${field('重复',select('repeat',repeatNames.map((label,i)=>[i,label]),current.repeat))}
      ${field('备注',textarea('remark',current.remark,3,'maxlength="12000"'),true)}
      <details><summary>子任务、标签与复盘</summary>
      ${field('子任务（每行一条）',textarea('children',current.children?.join('\n'),3))}
      ${field('标签（每行一个）',textarea('tags',current.tags?.join('\n'),2))}
      ${field('复盘',textarea('review',current.review,2,'maxlength="12000"'))}</details>
      ${fileFields(attachments)}</div>`;
  } else {
    current=existing?billSnapshot(ctx.state,existing):{ date:today(),type:'expense',currency:'CNY',channel:'支付宝',party:'支付宝余额',
      include_in_totals:1,include_in_party_stats:1 };
    const attachments=existing?filesOf(ctx.state,existing):[];
    const custom=list(ctx.state,team,T.option);
    const channels=['支付宝','微信','美团支付','抖音支付','银联云闪付','工行卡','建行卡','工行信用卡','建行信用卡','农行信用卡','招行卡','GooglePay','PayPal'];
    const parties=['支付宝余额','微信余额','工行卡','建行卡','工行信用卡','建行信用卡','农行信用卡','招行卡'];
    for (const option of custom) (option.data.kind==='channel'?channels:parties).push(option.data.name);
    body=`<div class="form-grid">
      ${field('事项',input('name',current.name,'maxlength="500" required autofocus'),true)}
      ${field('日期',input('date',current.date,'type="date" required'))}
      ${field('类型',select('type',Object.entries(billTypes),current.type))}
      ${field('金额',input('amount',current.amount,'inputmode="decimal" maxlength="49" required'))}
      ${field('币种',select('currency',[...new Set(['CNY','USD','HKD','EUR','JPY','GBP','SGD','AUD','CAD','KRW','TWD',current.currency])].map(code=>[code,code==='CNY'?'CNY · 人民币':code]),current.currency))}
      ${field('途径',input('channel',current.channel,'list="channels" maxlength="100" required')+datalist('channels',channels))}
      ${field('支出方 / 收入方',input('party',current.party,'list="parties" maxlength="100" required')+datalist('parties',parties))}
      ${check('include_in_totals','计入总支出／总收入',Number(current.include_in_totals))}
      ${check('include_in_party_stats',current.type==='income'?'计入收入统计':'计入支出统计',Number(current.include_in_party_stats))}
      ${field('地点',input('location',current.location,'maxlength="200"'),true)}
      ${field('备注',textarea('remark',current.remark,3,'maxlength="12000"'),true)}
      ${fileFields(attachments)}</div>`;
  }
  openDialog((existing?'编辑':'新建')+title,body,async(form)=>{
    const fields=new FormData(form);
    const files=fields.getAll('files').filter(file=>file instanceof File&&file.size>0);
    const attachmentTable=table===T.task?T.taskFile:T.billFile;
    const staged=await stageFiles(files,attachmentTable);
    await edit(state=>{
        const latest=get(state,team,table,uid);
        if (latest&&!versions(state,latest).length) captureVersion(state,account.id,latest);
        let saved;
        if (table===T.task) {
          const allDay=fields.has('allDay');
          const start=parseSchedule(fields.get('start'),allDay?'00:00':null,current.start);
          const end=start?((fields.get('end')?parseSchedule(fields.get('end'),allDay?'23:59':null,current.end)+(allDay?59:0):0)||
            (allDay?parseSchedule(String(fields.get('start')).slice(0,10),'23:59')+59:start+3600)):0;
          saved=saveTask(state,account.id,team,uid,{ ...current, name:String(fields.get('name')), rank:Number(fields.get('rank')),
            start, end, allDay, repeat:Number(fields.get('repeat')), alert:Number(fields.get('alert')),
            reminderMode:String(fields.get('reminderMode')), remark:String(fields.get('remark')||''),
            review:String(fields.get('review')||''),children:splitLines(fields.get('children')),tags:splitLines(fields.get('tags')),
          },account.personal);
        } else {
          const data=Object.fromEntries([...fields].filter(([key])=>!['detach','files'].includes(key)));
          saved=saveBill(state,account.id,team,uid,{ ...current, ...data, include_in_totals:fields.has('include_in_totals')?1:0,
            include_in_party_stats:fields.has('include_in_party_stats')?1:0,
            ...(data.location===current.location?{}:{latitude:'',longitude:''}) });
        }
        for (const file of filesOf(state,saved)) if (fields.getAll('detach').includes(file.uid)) {
          put(state,account.id,team,attachmentTable,file.uid,{ detached:1 });
        }
        addFiles(state,staged,account,saved,attachmentTable);
        captureVersion(state,account.id,saved);
    },staged);
    if (table===T.bill) {
      ctx.month=String(fields.get('date')).slice(0,7);
      ctx.archive=ctx.month!==today().slice(0,7);
      ctx.billFilter=null;
    }
    if (table===T.task&&!existing&&ctx.page==='tasks'&&ctx.filter==='done') ctx.filter='open';
    ctx.selected=uid;
    render();
    notify('已保存到本机');
  },existing?'保存':'创建');
  editorRecord=existing;
  if (existing) dialogPreviewObserver=observePreviews(dialog,existing);
}

function datalist(id,values) {
  return `<datalist id="${id}">${[...new Set(values.filter(Boolean))].map(value=>`<option value="${h(value)}"></option>`).join('')}</datalist>`;
}
function fileFields(files) {
  return `<section class="editor-attachments"><h3>附件</h3>
    ${files.length?`<div class="editor-files">${files.map(file=>`<div>${attachmentRow(file)}
      <label class="field-check"><input type="checkbox" name="detach" value="${h(file.uid)}">保存时移除</label></div>`).join('')}</div>`:''}
    ${field('添加图片、音频或文件','<input name="files" type="file" multiple>',true)}</section>`;
}
function parseSchedule(value,override,previous) {
  if (!value) return 0;
  if (!override && previous && whenLocal(previous)===value) return previous;
  const at=new Date(override ? String(value).slice(0,10)+'T'+override : value).getTime();
  if (!Number.isFinite(at)) throw new Error('计划时间无效');
  return Math.floor(at/1000);
}

async function migrationRows(row,entries) {
  return Promise.all(entries.filter(entry=>entry.legacy).map(async entry=>
    ({...entry,uid:'50-'+await digest(`${row.team}:${row.uid}:${entry.legacy}`)})));
}
function migrate(state,opened,current,migration,accountID) {
  if (!current || Number(current.data.conversation_version)) return;
  if (current.data.name!==opened?.data.name || current.data.attachments!==opened?.data.attachments) {
    throw new Error('便签已更新，请重新打开再编辑');
  }
  for (const entry of migration) put(state,accountID,current.team,T.entry,entry.uid,{ ...entry.data,note_id:current.uid });
}

function openNoteEditor(existing) {
  const team=ctx.team, section=ctx.noteSection;
  const key=JSON.stringify([team,section,existing?.uid||'']);
  let draft=noteEdits.get(key);
  if (!draft) {
    const entries=existing?noteEntries(ctx.state,existing):[];
    const body=entries.filter(row=>row.data.kind==='text').map(row=>row.data.content||'');
    draft={ key, team, section, existing, uid:existing?.uid||id(T.note), entries, body:body.length?body:[''],
      title:existing?noteTitle(existing):'', parent:existing?noteParent(existing):ctx.noteFolder, files:[] };
    noteEdits.set(key,draft);
  }
  ctx.selected=existing?.uid||null;
  ctx.noteEdit=draft;
  render();
  document.querySelector(existing&&section!=='quick'?'#note-edit-form textarea':'#note-edit-form [name=name]')?.focus();
}

async function saveNoteEdit(draft) {
  const local=workspace, account=ctx.account, {team,section,uid,existing,entries,parent}=draft;
  const name=draft.title.trim();
  if (!name) throw new Error('请输入便签标题');
  const staged=await stageFiles(draft.files,T.entry);
  const migration=existing?await migrationRows(existing,entries):[];
  const originals=entries.filter(row=>row.data.kind==='text');
  if (local!==workspace) throw new Error('登录状态已变更');
  await edit(state=>{
    const latest=get(state,team,T.note,uid);
    if (existing&&(!latest||latest.removed)) throw new Error('便签已删除');
    const legacy=latest&&!Number(latest.data.conversation_version);
    if (legacy) migrate(state,existing,latest,migration,account.id);
    const patch={conversation_version:1};
    if (!existing||legacy||name!==noteTitle(existing)) {
      if (latest&&!legacy&&noteTitle(latest)!==noteTitle(existing)&&noteTitle(latest)!==name) {
        throw new Error('标题已在另一台设备更新，请取消后重新打开');
      }
      Object.assign(patch,{name,title:name});
    }
    if (!existing||legacy) Object.assign(patch,{attachments:'[]',status:0});
    if ((!existing&&section!=='quick')||(customNotebook(section)&&parent!==noteParent(existing))) {
      if (parent&&!noteFolders(state,team,section).some(folder=>folder.uid===parent)) throw new Error('目录已失效，请重新选择');
      if (existing&&noteParent(latest)!==noteParent(existing)&&noteParent(latest)!==parent) {
        throw new Error('目录已在另一台设备修改，请取消后重新打开');
      }
      patch.notebook_section=documentSection(section,parent);
    }
    const saved=put(state,account.id,team,T.note,uid,patch);
    if (section!=='quick') {
      for (const [index,content] of draft.body.entries()) {
        const original=originals[index];
        if (original?.data.content===content || (!original&&!content)) continue;
        const key=original?.uid||migration.find(row=>row.legacy===original?.legacy)?.uid;
        if (!key) {
          put(state,account.id,team,T.entry,id(T.entry),{note_id:uid,kind:'text',content,entry_at:Date.now()});
          continue;
        }
        const previous=get(state,team,T.entry,key);
        if (!previous || previous.removed) throw new Error('段落已在另一台设备删除，请取消后重新打开');
        if (previous.data.content!==original.data.content&&previous.data.content!==content) {
          throw new Error('正文已在另一台设备更新，请取消后重新打开');
        }
        put(state,account.id,team,T.entry,key,{content});
      }
    }
    addFiles(state,staged,account,saved,T.entry);
  },staged);
  noteEdits.delete(draft.key);
  if (ctx.noteEdit===draft) Object.assign(ctx,{noteEdit:null,selected:uid,noteFolder:parent});
  render();
  notify('便签已保存');
}

function createFolderEditor() {
  const current=noteFolders(ctx.state,ctx.team,ctx.noteSection).find(folder=>folder.uid===ctx.noteFolder);
  ctx.folderDraft={name:'',parent:current&&current.depth<3?current.uid:''};
  render();
  document.querySelector('#folder-form [name=name]')?.focus();
}

async function submitFolder(draft) {
  const account=ctx.account.id, {team,noteSection:section}=ctx;
  const uid=id(T.note);
  await edit(state=>saveNoteFolder(state,account,team,section,uid,draft.name,draft.parent));
  if (ctx.folderDraft===draft) Object.assign(ctx,{folderDraft:null,noteFolder:uid});
  render();
}

async function sendNote(note,text,files=[]) {
  if (!text.trim() && !files.length) return;
  if (!note) throw new Error('请先打开一条速记');
  const account=ctx.account;
  const staged=await stageFiles(files,T.entry);
  const migration=await migrationRows(note,noteEntries(ctx.state,note));
  await edit(state=>{
    const latest=get(state,note.team,T.note,note.uid);
    if (!latest || latest.removed) throw new Error('便签已删除');
    if (!Number(latest.data.conversation_version)) {
      migrate(state,note,latest,migration,account.id);
      const name=noteTitle(latest);
      put(state,account.id,note.team,T.note,note.uid,{ name,title:name, conversation_version:1, attachments:'[]' });
    }
    if (text.trim()) put(state,account.id,note.team,T.entry,id(T.entry),{ note_id:note.uid,kind:'text',content:text.trim(),entry_at:Date.now() });
    addFiles(state,staged,account,note,T.entry);
  },staged);
  if (ctx.selected===note.uid) {
    if (text.trim()) ctx.noteDraft='';
    render({ bottom:true });
  }
}

function confirmAction(title,text,button,handler) {
  openDialog(title,`<p>${h(text)}</p>`,handler,button);
}

function showVersions(row) {
  if (!row) return;
  const items=versions(ctx.state,row);
  openDialog('历史版本',items.length?`<div class="versions">${items.map(item=>{
    let snapshot;
    try { snapshot=JSON.parse(item.data.snapshot); } catch {}
    return `<div class="version-row"><div><strong>${h(snapshot?.name||item.data.action)}</strong><br>
      <small>${h(whenText(Number(item.data.version_at)))} · ${h(item.data.action)}</small></div>
      <button class="button secondary" data-act="restore-version" data-record="${h(row.uid)}" data-id="${h(item.uid)}" ${snapshot?'':'disabled'}>还原</button></div>`;
  }).join('')}</div>`:'<p>暂无历史版本。</p>');
}

async function restoreVersion(row, versionID) {
  const version=versions(ctx.state,row).find(item=>item.uid===versionID);
  if (!version) return;
  const snapshot=JSON.parse(version.data.snapshot);
  confirmAction('还原版本','当前内容会保留在历史版本中。','还原',async()=>{
    const account=ctx.account;
    await edit(state=>{
      const current=get(state,row.team,row.table,row.uid);
      captureVersion(state,account.id,current);
      let fields=snapshot;
      if (row.table===T.task&&row.team!==account.personal) {
        const {alert,reminderMode}=taskSnapshot(state,current,account.id);
        fields={...snapshot,alert,reminderMode};
      }
      const restored=row.table===T.task?saveTask(state,account.id,row.team,row.uid,fields,account.personal):
        saveBill(state,account.id,row.team,row.uid,snapshot);
      if (row.table===T.task&&row.team===account.personal) restoreTaskChecks(state,account.id,restored,snapshot);
      for (const file of filesOf(state,restored,true)) put(state,account.id,row.team,file.table,file.uid,
        { detached:snapshot.attachments?.includes(file.uid)?0:1 });
      captureVersion(state,account.id,restored,'还原版本');
    });
    notify('已还原版本');
  });
}

function deleteRecord(row) {
  if (!row) return;
  const note=row.table===T.note;
  confirmAction(note?'删除便签':'移到回收站',note?'删除《'+noteTitle(row)+'》及其内容？':'将《'+row.data.name+'》移到回收站？',
    note?'删除':'移到回收站',async()=>{
      await edit(state=>{
        const current=get(state,row.team,row.table,row.uid);
        if (!current||current.removed) return;
        if (note) for (const item of noteEntries(state,current)) {
          if (item.uid) remove(state,item);
        } else captureVersion(state,ctx.account.id,current,'删除');
        remove(state,current);
      });
      ctx.selected=null;
      render();
    });
}

function schedulePreviews() {
  previewObserver?.disconnect();
  const row=record();
  if (row) previewObserver=observePreviews(app,row);
}
function observePreviews(root,parent) {
  const files=recordFiles(parent);
  const observer=new IntersectionObserver(entries=>{
    for (const entry of entries) if (entry.isIntersecting) {
      observer.unobserve(entry.target);
      const file=files.find(file=>(file.uid||file.legacy)===entry.target.dataset.preview);
      if (file) void fillPreview(entry.target,file);
    }
  });
  for (const node of root.querySelectorAll('[data-preview]')) observer.observe(node);
  return observer;
}
const imageType=/^image\/(?:png|jpeg|gif|webp|avif|bmp|heic|heif)$/i;
const audioType=/^audio\/(?:wav|mpeg|mp4|ogg|webm|aac|x-wav|x-m4a)$/i;
function elementFor(blob,url) {
  if (imageType.test(blob.type)) {
    const item=new Image();item.alt='附件图片';item.src=url;return item;
  }
  if (audioType.test(blob.type)) {
    const item=document.createElement('audio');item.controls=true;item.preload='metadata';item.src=url;return item;
  }
  return null;
}
async function previewBlob(blob) {
  if (imageType.test(blob.type)||audioType.test(blob.type)) return blob;
  // Older file attachments may have a generic MIME type. Only enable inline
  // display when the bytes identify a supported passive image format.
  const bytes=new Uint8Array(await blob.slice(0,16).arrayBuffer());
  const head=new TextDecoder('latin1').decode(bytes);
  const type=bytes[0]===137&&head.slice(1,8)==='PNG\r\n\x1a\n'?'image/png':
    bytes[0]===255&&bytes[1]===216&&bytes[2]===255?'image/jpeg':
    /^GIF8[79]a/.test(head)?'image/gif':
    head.startsWith('RIFF')&&head.slice(8,12)==='WEBP'?'image/webp':'';
  return type?blob.slice(0,blob.size,type):blob;
}
async function fillPreview(node,row) {
  const local=workspace;
  if (!local) return;
  const key=[row.team,row.uid||row.legacy,row.data.media_id,row.data.client_media_id,row.data.sha256].join(':');
  const status=node.querySelector('.preview-status');
  let cached=media.get(key);
  if (!cached) {
    cached={ promise:local.file(row).then(previewBlob) };
    media.set(key,cached);
  }
  try {
    const blob=await cached.promise;
    if (workspace!==local || !node.isConnected) return;
    if (!cached.url) cached.url=URL.createObjectURL(blob);
    const element=elementFor(blob,cached.url);
    if (element instanceof HTMLImageElement) {
      const button=node.querySelector('.file-chip');
      element.alt='';
      button.prepend(element);
      button.classList.add('thumbnail-button');
      element.addEventListener('error',()=>{
        element.remove();button.classList.remove('thumbnail-button');
        status.textContent='此图片无法预览，可下载原文件';
      },{once:true});
    } else if (element) {
      node.prepend(element);
    } else if (row.data.kind==='image') {
      status.textContent='此图片格式无法预览，可下载原文件';
    }
  } catch (error) {
    if (media.get(key)===cached) media.delete(key);
    if (node.isConnected && workspace===local) status.textContent=error.message;
  }
}

function recordFiles(row) {
  return row.table===T.note?noteEntries(ctx.state,row).filter(item=>item.data.kind!=='text'):filesOf(ctx.state,row);
}

async function openMedia(button) {
  const row=dialog.contains(button)?editorRecord:record(), local=workspace;
  if (!row || !local) return;
  const file=recordFiles(row).find(item=>(item.uid||item.legacy)===button.dataset.id);
  if (!file) return;
  await showMedia(file.data.media_name||'附件',async()=>local.file(file));
}

async function showMedia(name, readFile) {
  const job=++mediaJob;
  if (modalURL) URL.revokeObjectURL(modalURL);
  modalURL=null;
  mediaDialog.innerHTML=`<div class="dialog-head"><h2 id="media-title">${h(name)}</h2>
    <button class="icon-button" type="button" data-act="close-media" aria-label="关闭预览">${icon('close',18)}</button></div>
    <div class="dialog-body"><div class="media-display" role="status">正在读取附件…</div></div>`;
  if (!mediaDialog.open) mediaDialog.showModal();
  try {
    const blob=await previewBlob(await readFile());
    if (job!==mediaJob||!mediaDialog.open) return;
    modalURL=URL.createObjectURL(blob);
    const display=mediaDialog.querySelector('.media-display'), preview=elementFor(blob,modalURL);
    display.replaceChildren();
    if (preview) display.append(preview);
    preview?.addEventListener('error',()=>{
      preview.remove();
      display.prepend('浏览器无法预览此附件。');
    },{once:true});
    const link=document.createElement('a');
    link.className='button secondary';link.download=name;link.href=modalURL;link.textContent='下载原文件';display.append(link);
  } catch (error) {
    if (job===mediaJob&&mediaDialog.open) mediaDialog.querySelector('.media-display').textContent=error.message;
  }
}

async function toggleRecording() {
  if (noteRecorder?.state==='recording') { noteRecorder.stop(); return; }
  const note=record(), local=workspace;
  if (!note || !navigator.mediaDevices?.getUserMedia || typeof MediaRecorder==='undefined') throw new Error('此浏览器无法录音');
  const stream=await navigator.mediaDevices.getUserMedia({audio:true});
  if (workspace!==local) { stream.getTracks().forEach(track=>track.stop()); return; }
  try {
    const mime=['audio/mp4','audio/ogg','audio/webm'].find(value=>MediaRecorder.isTypeSupported(value));
    const recorder=noteRecorder=new MediaRecorder(stream,mime?{mimeType:mime}:{});
    const chunks=[];
    recorder.ondataavailable=event=>{ if (event.data.size) chunks.push(event.data); };
    recorder.onstop=()=>{
      stream.getTracks().forEach(track=>track.stop());
      const type=recorder.mimeType.split(';')[0],ext=type==='audio/mp4'?'m4a':type==='audio/ogg'?'ogg':'webm';
      ctx.recording=false;
      render();
      if (workspace===local && chunks.length) {
        const file=new File(chunks,'录音.'+ext,{type});
        const compatible=type==='audio/webm'?encodeWave(file):Promise.resolve(file);
        void compatible.then(recording=>workspace===local&&sendNote(note,'',[recording])).catch(error=>notify(error.message));
      }
    };
    recorder.start();
    ctx.recording=true;
    render();
  } catch (error) {
    stream.getTracks().forEach(track=>track.stop());
    throw error;
  }
}

async function encodeWave(blob) {
  const context=new AudioContext({sampleRate:16000});
  try {
    const decoded=await context.decodeAudioData(await blob.arrayBuffer());
    const pcm=decoded.getChannelData(0);
    const buffer=new ArrayBuffer(44+pcm.length*2);
    const header=new DataView(buffer);
    for(const [offset,value] of [[0,'RIFF'],[8,'WAVE'],[12,'fmt '],[36,'data']]) {
      for(let i=0;i<value.length;i++) header.setUint8(offset+i,value.charCodeAt(i));
    }
    header.setUint32(4,buffer.byteLength-8,true);
    header.setUint32(16,16,true);
    header.setUint16(20,1,true);header.setUint16(22,1,true);
    header.setUint32(24,decoded.sampleRate,true);header.setUint32(28,decoded.sampleRate*2,true);
    header.setUint16(32,2,true);header.setUint16(34,16,true);
    header.setUint32(40,pcm.length*2,true);
    for(let i=0;i<pcm.length;i++)header.setInt16(44+i*2,Math.max(-32768,Math.min(32767,pcm[i]*32768)),true);
    return new File([buffer],'录音.wav',{type:'audio/wav'});
  } finally { await context.close(); }
}

function dictate(which) {
  if (!SpeechRecognition) return;
  const field=document.querySelector(which==='ai'?'#ai-send textarea':'#note-send textarea');
  if (!field) return;
  const voice=new SpeechRecognition();
  voice.lang='zh-CN';
  voice.onresult=event=>{
    const value=[...event.results].map(result=>result[0].transcript).join('');
    if (!field.isConnected) return;
    field.setRangeText(value,field.selectionStart,field.selectionEnd,'end');
    field.dispatchEvent(new Event('input',{bubbles:true}));
    field.focus();
  };
  voice.onerror=()=>notify('语音识别不可用，请检查麦克风和浏览器设置');
  voice.start();
  notify('正在听，请开始说话');
}

async function loadConversations(openLatest=false) {
  const local=workspace;
  try {
    const reply=await request('ai/list',{});
    if (workspace!==local) return;
    ctx.ai.conversations=Array.isArray(reply.data)?reply.data:[];
    if (openLatest && !ctx.ai.thread && ctx.ai.conversations[0]?.thread) await openThread(ctx.ai.conversations[0].thread);
    else if (ctx.page==='ai') render();
  } catch (error) { if (workspace===local && ctx.page==='ai') notify(error.message); }
}
async function openThread(thread, scroll=true) {
  const local=workspace;
  clearTimeout(aiTimer);
  if (ctx.ai.thread!==thread) {
    ctx.ai.thread=thread;ctx.ai.turns=[];ctx.ai.loading=true;render();
  }
  try {
    const reply=await request('ai/list',{thread});
    if (workspace!==local || ctx.ai.thread!==thread) return;
    const turns=Array.isArray(reply.data)?reply.data:[];
    const changed=JSON.stringify(turns)!==JSON.stringify(ctx.ai.turns);
    ctx.ai.turns=turns;
    ctx.ai.loading=false;
    if (ctx.page==='ai' && (changed||scroll)) render({bottom:scroll||changed});
    if (turns.some(turn=>['queued','running','processing'].includes(turn.state))) {
      aiTimer=setTimeout(()=>{if(ctx.page==='ai')void openThread(thread,false);},2400);
    }
  } catch (error) {
    if (workspace!==local||ctx.ai.thread!==thread) return;
    ctx.ai.loading=false;
    if (ctx.page==='ai') {render();notify(error.message);}
  }
}
const base64=async file=>new Promise((resolve,reject)=>{
  const reader=new FileReader();
  reader.onload=()=>resolve(String(reader.result).split(',')[1]);
  reader.onerror=()=>reject(reader.error);
  reader.readAsDataURL(file);
});
async function sendAI() {
  const local=workspace;
  if (ctx.ai.sending) return;
  const question=ctx.ai.draft.trim(), file=ctx.ai.file;
  if (!question&&!file) return;
  const thread=ctx.ai.thread ||= 'chat-'+crypto.randomUUID();
  const draft=ctx.ai.retry;
  const requestID=draft?.question===question&&draft.file===file ? draft.id : 'ask-'+crypto.randomUUID();
  ctx.ai.retry={question,file,id:requestID};
  ctx.ai.sending=true;render();
  try {
    await request('ai/send',{thread, question, request_id:requestID, timezone:Intl.DateTimeFormat().resolvedOptions().timeZone,
      ...(file?{image:await base64(file)}:{})});
    if (workspace!==local) return;
    if (ctx.ai.draft.trim()===question) ctx.ai.draft='';
    if (ctx.ai.file===file) ctx.ai.file=null;
    ctx.ai.retry=null;
    if (ctx.ai.thread===thread) await openThread(thread);
    void loadConversations();
  } finally {
    if (workspace===local) {ctx.ai.sending=false;render({bottom:true});}
  }
}

function selectRow(uid) {
  if (ctx.selected!==uid && ctx.page==='notes') {
    ctx.noteDraft='';
    ctx.noteEdit=null;
    const note=record(uid,T.note);
    if (note) ctx.noteFolder=noteParent(note);
  }
  ctx.selected=uid;
  render({ bottom:ctx.page==='notes' });
  if (matchMedia('(max-width: 940px)').matches) {
    document.querySelector(ctx.page==='notes'?'.note-content':'.inspector')?.scrollIntoView({block:'nearest'});
  }
}

const minYear=1970, maxYear=9999;
function moveCalendar(year, month) {
  const target=new Date(year,month,1);
  if (target.getFullYear()<minYear||target.getFullYear()>maxYear) return;
  ctx.calendarDate=target;
  const day=Math.min(Number(ctx.day?.slice(8))||1,new Date(year,month+1,0).getDate());
  ctx.day=dateKey(new Date(year,month,day));
  ctx.selected=null;
  render();
}

function revealYearDay() {
  const grid=document.querySelector('#year-month-grid');
  const day=grid?.querySelector('.mini-day[aria-pressed="true"]');
  if (!day||grid.scrollHeight<=grid.clientHeight) return;
  const viewport=grid.getBoundingClientRect(), target=day.getBoundingClientRect();
  if (target.top<viewport.top) grid.scrollTop+=target.top-viewport.top-8;
  else if (target.bottom>viewport.bottom) grid.scrollTop+=target.bottom-viewport.bottom+8;
}

let wheelOffset=0, lastWheelAt=0, lastWheelMonthAt=-Infinity, lastWheelDirection=0;
app.addEventListener('wheel',event=>{
  if (ctx.page!=='timeline'||ctx.calendarView!=='month'||event.ctrlKey||event.metaKey||event.shiftKey||
      !event.target.closest?.('.calendar-days,.calendar-weekdays')||Math.abs(event.deltaY)<=Math.abs(event.deltaX)) return;
  event.preventDefault();
  const now=performance.now(), direction=Math.sign(event.deltaY);
  if (now-lastWheelAt>160||Math.sign(wheelOffset)!==direction) wheelOffset=0;
  lastWheelAt=now;
  if (direction===lastWheelDirection&&now-lastWheelMonthAt<180) return;
  wheelOffset+=event.deltaY*(event.deltaMode===1?16:event.deltaMode===2?window.innerHeight:1);
  if (Math.abs(wheelOffset)<24) return;
  wheelOffset=0;
  lastWheelDirection=direction;
  lastWheelMonthAt=now;
  moveCalendar(ctx.calendarDate.getFullYear(),ctx.calendarDate.getMonth()-direction);
},{passive:false});

async function interact(button) {
  const act=button.dataset.act, data=button.dataset;
  if (act==='close') { dialog.close();return; }
  if (act==='close-media') { mediaDialog.close();return; }
  if (act==='qr-refresh') { await startLogin();return; }
  if (!ctx.account || !ctx.state) return;
  switch(act) {
    case 'sync':await sync();break;
    case 'logout':
      confirmAction('退出登录','未同步的改动会保留在此浏览器中，下次登录同一账号后继续同步。','退出',async()=>{
        await request('logout',{});void forgetAccount();
      });break;
    case 'new':editor(undefined,Number(data.rank)||1);break;
    case 'select':selectRow(data.id);break;
    case 'edit':editor(record(data.id||ctx.selected));break;
    case 'clear-selection':ctx.selected=null;render();break;
    case 'delete':deleteRecord(record());break;
    case 'complete': {
      const row=record(data.id,T.task);
      if (row) await edit(state=>toggleTask(state,ctx.account.id,row,Number(data.time)||0));
      break;
    }
    case 'task-filter':ctx.filter=data.filter;render();break;
    case 'calendar-view':
      ctx.calendarView=data.view;render();
      if (data.view==='year') revealYearDay();
      break;
    case 'calendar-prev':case 'calendar-next': {
      const step=act==='calendar-next'?1:-1;
      const year=ctx.calendarDate.getFullYear(), month=ctx.calendarDate.getMonth();
      moveCalendar(year+(ctx.calendarView==='year'?step:0),month+(ctx.calendarView==='month'?step:0));
      break;
    }
    case 'calendar-year':
      openDialog('跳转年份',field('年份',input('year',ctx.calendarDate.getFullYear(),
        `type="number" min="${minYear}" max="${maxYear}" step="1" required autofocus`),true),async form=>{
        moveCalendar(Number(new FormData(form).get('year')),ctx.calendarDate.getMonth());
      },'跳转');
      break;
    case 'day':
      ctx.day=data.date;
      ctx.calendarDate=new Date(data.date+'T00:00:00');
      ctx.selected=null;render();revealYearDay();break;
    case 'today':ctx.calendarDate=new Date();ctx.day=today();ctx.selected=null;render();revealYearDay();break;
    case 'current-month':
      Object.assign(ctx,{archive:false,month:today().slice(0,7),billFilter:null,selected:null});render();break;
    case 'archive':
      ctx.archive=!ctx.archive;
      if (!ctx.archive) ctx.month=today().slice(0,7);
      ctx.billFilter=null;ctx.selected=null;render();break;
    case 'month':ctx.month=data.month;ctx.billFilter=null;ctx.selected=null;render();break;
    case 'bill-filter': {
      const filter={type:data.type,code:data.code,party:data.party};
      ctx.billFilter=JSON.stringify(ctx.billFilter)===JSON.stringify(filter)?null:filter;
      ctx.selected=null;render();break;
    }
    case 'bill-unfilter':ctx.billFilter=null;render();break;
    case 'note-section':
      Object.assign(ctx,{noteSection:data.section,selected:null,noteDraft:'',noteFolder:'',folderDraft:null,noteEdit:null});
      render();break;
    case 'note-folder':
      ctx.noteFolder=data.id;render();break;
    case 'folder-new':createFolderEditor();break;
    case 'folder-cancel':ctx.folderDraft=null;render();break;
    case 'note-edit-cancel':
      if (ctx.noteEdit) noteEdits.delete(ctx.noteEdit.key);
      ctx.noteEdit=null;render();break;
    case 'note-files-clear':
      if (ctx.noteEdit) ctx.noteEdit.files=[];
      render();break;
    case 'open-media':await openMedia(button);break;
    case 'remove-entry': {
      const row=record(data.id,T.entry), note=record();
      if (row?.data.note_id!==note?.uid) break;
      confirmAction('删除这条记录','图片、语音或文字将从此便签中移除。','删除',async()=>{
        await edit(state=>remove(state,row));
      });break;
    }
    case 'record':await toggleRecording();break;
    case 'dictate-note':dictate('note');break;
    case 'dictate-ai':dictate('ai');break;
    case 'versions':showVersions(record());break;
    case 'restore-version':await restoreVersion(record(data.record),data.id);break;
    case 'restore': {
      const row=record(data.id,Number(data.table));
      if (!row?.removed) break;
      await edit(state=>put(state,ctx.account.id,row.team,row.table,row.uid,{},true));
      notify('已恢复记录');break;
    }
    case 'ai-thread':if(!ctx.ai.sending)await openThread(data.id);break;
    case 'ai-new':
      if (!ctx.ai.sending) {
        ctx.ai.thread='chat-'+crypto.randomUUID();ctx.ai.turns=[];ctx.ai.loading=false;ctx.ai.draft='';ctx.ai.file=null;
        clearTimeout(aiTimer);render();
        document.querySelector('#ai-send textarea')?.focus();
      }break;
    case 'ai-remove':ctx.ai.file=null;render();break;
    case 'ai-image':
      await showMedia('对话图片',async()=>{
        const {data:result}=await request('ai/image',{id:Number(data.id)});
        const value=String(result.image||'');
        return new Blob([Uint8Array.from(atob(value),ch=>ch.charCodeAt(0))],{ type:result.content_type||'image/png' });
      });break;
  }
}

document.addEventListener('click',event=>{
  const button=event.target.closest('[data-act]');
  if (button) void interact(button).catch(error=>notify(error.message));
});
document.addEventListener('input',event=>{
  const control=event.target;
  if (control.id==='search') {ctx.query=control.value;if(!composing)render();}
  else if (control.closest('#note-edit-form')&&ctx.noteEdit) {
    if (control.name==='name') ctx.noteEdit.title=control.value;
    else if (control.name==='parent') ctx.noteEdit.parent=control.value;
    else if (control.name?.startsWith('body')) ctx.noteEdit.body[Number(control.name.slice(4))]=control.value;
  } else if (control.closest('#folder-form')&&ctx.folderDraft&&['name','parent'].includes(control.name)) {
    ctx.folderDraft[control.name]=control.value;
  }
  else if (control.closest('#note-send')) ctx.noteDraft=control.value;
  else if (control.closest('#ai-send')&&control.name==='text') ctx.ai.draft=control.value;
});
document.addEventListener('compositionstart',()=>{composing=true;});
document.addEventListener('compositionend',()=>{composing=false;});
document.addEventListener('change',event=>{
  const control=event.target;
  if (control.id==='space') {
    Object.assign(ctx,{team:Number(control.value),selected:null,billFilter:null,noteDraft:'',noteFolder:'',folderDraft:null,noteEdit:null});
    render();
  }
  else if (control.id==='document-images'&&ctx.noteEdit&&control.files?.length) {
    ctx.noteEdit.files.push(...control.files);
    render();
  }
  else if (control.id==='note-files'&&control.files?.length) {
    const files=[...control.files];control.value='';
    void sendNote(record(),'',files).catch(error=>notify(error.message));
  } else if (control.id==='ai-file'&&control.files?.length) {
    const file=control.files[0];
    if (file.size>3*1024*1024-3 || !imageType.test(file.type)) {control.value='';notify('请选择 3 MB 以内的图片');return;}
    ctx.ai.file=file;render();
  } else if (control.name==='channel'&&control.value==='微信') {
    control.form.elements.party.value='微信余额';
  } else if (control.name==='type'&&control.closest('#modal-form')) {
    const field=control.form.elements.include_in_party_stats;
    if (field) field.parentElement.lastChild.textContent=control.value==='income'?'计入收入统计':'计入支出统计';
  }
});

document.addEventListener('submit',async event=>{
  event.preventDefault();
  const form=event.target;
  if (form.id==='note-edit-form'||form.id==='folder-form') {
    const documentForm=form.id==='note-edit-form';
    const draft=documentForm?ctx.noteEdit:ctx.folderDraft;
    if (!draft||draft.saving) return;
    draft.saving=true;draft.error='';form.inert=true;
    try {await (documentForm?saveNoteEdit(draft):submitFolder(draft));}
    catch(error){draft.error=error.message;}
    finally {draft.saving=false;render();}
    return;
  }
  if (form.id==='modal-form'&&formHandler) {
    const errorBox=form.querySelector('.error-text'), button=form.querySelector('[type=submit]');
    if (button.disabled) return;
    button.disabled=true;errorBox.textContent='';
    try {await formHandler(form);if(dialog.open&&form.isConnected)dialog.close();}
    catch(error){errorBox.textContent=error.message;}
    finally {button.disabled=false;}
    return;
  }
  const button=form.querySelector('[type=submit]');
  if (button?.disabled) return;
  if (button) button.disabled=true;
  try {
    if (form.id==='note-send') await sendNote(record(),new FormData(form).get('text')||'');
    if (form.id==='ai-send') await sendAI();
  } catch(error){notify(error.message);}
  finally {if(button)button.disabled=false;}
});
dialog.addEventListener('close',()=>{
  if (dialog.open) return;
  editorRecord=null;
  dialogPreviewObserver?.disconnect();
  formHandler=null;
});
mediaDialog.addEventListener('close',()=>{
  if (mediaDialog.open) return;
  mediaJob++;
  if (modalURL) URL.revokeObjectURL(modalURL);
  modalURL=null;
});

window.addEventListener('hashchange',()=>{
  const page=pageFromHash(), previous=ctx.page;
  if (previous===page) return;
  Object.assign(ctx,{page,selected:null,query:'',day:page==='timeline'?today():null,calendarDate:new Date(),
    filter:defaultFilter(page),noteDraft:'',noteFolder:'',folderDraft:null,noteEdit:null});
  if (page==='bills') ctx.billFilter=null;
  render();window.scrollTo(0,0);
  if (page==='ai') {
    if (ctx.ai.thread) void openThread(ctx.ai.thread);
    void loadConversations(!ctx.ai.thread);
  }
});
window.addEventListener('online',()=>void sync());
window.addEventListener('keydown',event=>{
  if (event.isComposing || !ctx.account || event.defaultPrevented) return;
  const command=event.ctrlKey||event.metaKey;
  const miniDay=event.target.closest?.('.mini-day');
  const offset={ArrowLeft:-1,ArrowRight:1,ArrowUp:-7,ArrowDown:7}[event.key];
  if (miniDay&&offset&&!command&&!event.altKey) {
    event.preventDefault();
    const target=dateKey(addDays(new Date(miniDay.dataset.date+'T00:00:00'),offset));
    const cell=app.querySelector(`.mini-day[data-date="${target}"]`);
    if (cell) {
      const previous=app.querySelector('.mini-day[tabindex="0"]');
      if (previous) previous.tabIndex=-1;
      cell.tabIndex=0;
      cell.focus();
    }
    return;
  }
  if (command&&event.key.toLowerCase()==='k'&&!dialog.open) {
    const search=document.querySelector('#search');
    if (search) {event.preventDefault();search.focus();search.select();}
  } else if (command&&event.key==='Enter') {
    const form=event.target.closest('form');
    if(form){event.preventDefault();form.requestSubmit();}
  } else if (command&&event.altKey&&event.key.toLowerCase()==='n'&&!dialog.open&&['tasks','timeline','bills','notes'].includes(ctx.page)) {
    event.preventDefault();editor();
  }
});

if (ctx.page==='timeline') ctx.day=today();
render();
try {
  const {account}=await request('session');
  if(account) await signIn(account);
  else await startLogin();
} catch(error) {
  ctx.account=null;
  login={loading:false,message:error.message};
  render();
}
