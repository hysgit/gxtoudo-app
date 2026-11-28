export const T = Object.freeze({ note:49, entry:50, bill:51, billFile:52, option:53, taskFile:54,
  taskHistory:55, billHistory:56, tag:59, place:69, check:76, alarm:77, repeat:78, schedule:79,
  subcheck:83, taskTag:84, detail:86, subtask:87, assignee:88, task:89 });
const known = new Set([...Object.values(T), 98, 99]);
export const fileParent = { [T.entry]:T.note, [T.billFile]:T.bill, [T.taskFile]:T.task };
export const priorities = ['普通', '重要', '紧急', '重要且紧急'];
export const repeatNames = ['不重复', '每天', '每周', '每个工作日', '每月', '每年'];
export const reminders = [[-1,'无提醒'],[0,'开始时'],[300,'提前 5 分钟'],[600,'提前 10 分钟'],
  [1800,'提前 30 分钟'],[3600,'提前 1 小时'],[86400,'提前 1 天']];
export const billTypes = { expense:'支出', income:'收入', transfer:'内转' };
export const rowKey = (team, table, uid) => JSON.stringify([Number(team), Number(table), uid]);
export const id = table => table + '-' + crypto.randomUUID().replaceAll('-', '');
export const stamp = ms => new Date(ms).toISOString().slice(0, 19).replace('T', ' ');
export const utcDate = value => new Date(value && !/Z$|[+-]\d{2}:\d{2}$/.test(value) ? value.replace(' ', 'T') + 'Z' : value || 0);
const pad = value => String(value).padStart(2, '0');
export const dateKey = date => `${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())}`;
export const clock = date => `${pad(date.getHours())}:${pad(date.getMinutes())}`;
export const localDay = date => new Date(date.getFullYear(), date.getMonth(), date.getDate());
export const addDays = (date, count) => new Date(date.getFullYear(), date.getMonth(), date.getDate()+count);
export const calendarIndex = date => Date.UTC(date.getFullYear(),date.getMonth(),date.getDate()) / 86400000;
export const dayText = date => `${date.getMonth()+1}月${date.getDate()}日`;
export const whenText = time => {
  const date = new Date(time);
  return Number.isFinite(date.getTime())&&date.getTime()>0 ? dateKey(date)+' '+clock(date) : '';
};
export const get = (state, team, table, uid) => state.rows[rowKey(team, table, uid)];
export const list = (state, team, table, deleted = false) => Object.values(state.rows)
  .filter(row => row.team === team && row.table === table && row.removed === deleted);
export const related = (state, row, table, key) => list(state, row.team, table).filter(item => item.data[key] === row.uid);
export const filesOf = (state, row, detached = false) => related(state, row, row.table === T.task ? T.taskFile : T.billFile, 'note_id')
  .filter(file => detached || !Number(file.data.detached));

export function put(state, user, team, table, uid, patch, restore = false) {
  const key = rowKey(team, table, uid);
  const previous = state.rows[key];
  if (previous?.removed && !restore) throw new Error('这条记录已删除，请重新打开');
  const edited = Math.max(Date.now(), (previous?.edited || 0) + 1);
  const data = { ...(previous?.data || { created_at:stamp(edited) }), ...patch, uid, team_id:team,
    user_id:previous?.data.user_id ?? patch.user_id ?? user };
  if (restore) delete data.deleted_at;
  if (previous && !previous.removed && Object.keys(data).every(key => data[key] === previous.data[key])) return previous;
  data.updated_at = stamp(edited);
  const pending = previous?.removed || previous?.pending === 4 ? 4 : !previous || previous.pending === 1 ? 1 : 2;
  return state.rows[key] = { team, table, uid, data, pending, edited, revision:previous?.revision || 0, removed:false };
}

export function remove(state, row) {
  const key = rowKey(row.team, row.table, row.uid);
  const current = state.rows[key];
  if (current && !current.removed) {
    state.rows[key] = { ...current, removed:true, pending:3, edited:Math.max(Date.now(), current.edited+1) };
  }
}

export function applyPage(state, sent, reply) {
  if (![reply.data, reply.down, reply.down_extra].every(Array.isArray)) throw new Error('同步响应不完整');
  const batch = new Map(sent.map(row => [row.uid, row]));
  for (const ack of reply.data) {
    const previous = batch.get(ack.uid || ack.id);
    const revision = Number(ack.entropy);
    if (!previous || Number(ack.status) !== 0 || revision <= 0) continue;
    const local = get(state, previous.team, previous.table, previous.uid);
    if (!local) continue;
    local.revision = Math.max(local.revision, revision);
    if (local.edited === previous.edited) local.pending = 0;
    else if (local.pending === 1) local.pending = 2;
    batch.delete(previous.uid);
  }
  if (batch.size) throw new Error('部分改动等待同步，本机数据已保留');
  const active = new Set(state.spaces.map(space => Number(space.id)));
  for (const change of reply.down) {
    const table = Number(change.table_id), data = change.data;
    if (!data || typeof data !== 'object') throw new Error('服务端下发了无效记录');
    if (table === 12) {
      const index = state.spaces.findIndex(space => Number(space.id) === Number(data.id));
      if (index >= 0 && data.name) state.spaces[index] = data;
      continue;
    }
    if (!known.has(table)) continue;
    const team = Number(data.team_id), uid = data.uid, revision = Number(change.sync_entropy);
    if (!active.has(team) || !uid || revision <= 0) throw new Error('服务端下发了无效记录');
    const key = rowKey(team, table, uid), previous = state.rows[key];
    if (previous?.pending || (previous?.revision || 0) > revision) continue;
    const removed = Number(change.edit_mode) === 3;
    state.rows[key] = { team, table, uid, revision, removed, pending:0, data,
      edited:removed && data.deleted_at ? Number(data.deleted_at) : utcDate(data.updated_at).getTime() || previous?.edited || 0 };
  }
  for (const mark of reply.down_extra) {
    const team = Number(mark.team_id), key = 't' + team;
    if (active.has(team)) state.cursors[key] = Number(mark.entropy) || 0;
  }
}

export function pendingRows(state) {
  const active = new Set(state.spaces.map(space => Number(space.id)));
  const changes = Object.values(state.rows).filter(row => row.pending && active.has(row.team) &&
    (row.removed || !fileParent[row.table] || row.data.kind === 'text' || row.data.media_id))
    .sort((a,b) => a.edited-b.edited || a.table-b.table);
  const batch = [];
  let bytes = 0;
  for (const row of changes.slice(0,300)) {
    const data = row.removed && row.table !== T.task && row.table !== T.bill
      ? { uid:row.uid, team_id:row.team, user_id:row.data.user_id } : row.data;
    const payload = { table:row.table, mode:row.pending, edit_time:row.edited, entropy:row.revision, data };
    bytes += new TextEncoder().encode(JSON.stringify(payload)).length;
    if (bytes > 8 * 1024 * 1024) break;
    batch.push({ row, payload });
  }
  if (changes.length && !batch.length) throw new Error('单条记录超出同步大小限制');
  return batch;
}

export function repeatKind(rule) {
  if (Number(rule.repeat_start_day)>0) return 1;
  if (Number(rule.repeat_start_week)>0) return rule.weekday === '0234560' ? 3 : 2;
  if (Number(rule.repeat_start_month)>0) return 4;
  return Number(rule.repeat_start_year)>0 ? 5 : 0;
}

export function occurs(start, rule, day) {
  if (!start) return 0;
  const first = new Date(start*1000);
  const elapsed = calendarIndex(day) - calendarIndex(first);
  if (elapsed < 0) return 0;
  const when = Math.floor(new Date(day.getFullYear(), day.getMonth(), day.getDate(), first.getHours(),
    first.getMinutes(), first.getSeconds()).getTime()/1000);
  if (Number(rule.repeat_end)>0 && when>Number(rule.repeat_end)) return 0;
  const kind = repeatKind(rule), count = Number(rule.repeat_count)||0;
  const within = index => !count || index < count;
  let valid;
  if (kind === 1) {
    const interval = Math.max(1, Math.floor((Number(rule.day_interval)||0)/86400));
    valid = elapsed % interval === 0 && within(elapsed/interval);
  } else if (kind === 2 || kind === 3) {
    const mask = String(rule.weekday || '');
    const offset = elapsed + first.getDay(), week = Math.floor(offset/7);
    const interval = Math.max(1, Math.floor((Number(rule.week_interval)||0)/604800));
    const nonzero = value => value.replaceAll('0','').length;
    const instances = week ? nonzero(mask.slice(first.getDay())) + Math.floor((week-1)/interval)*nonzero(mask) +
      (week % interval === 0 ? nonzero(mask.slice(0,day.getDay()+1)) : 0) : nonzero(mask.slice(first.getDay(),day.getDay()+1));
    valid = mask.length === 7 && mask[day.getDay()] !== '0' && week % interval === 0 && within(instances-1);
  } else if (kind === 4 || kind === 5) {
    const years = day.getFullYear()-first.getFullYear();
    const months = years*12 + day.getMonth()-first.getMonth();
    const monthDay = Math.min(Number(rule.day)||first.getDate(), new Date(day.getFullYear(),day.getMonth()+1,0).getDate());
    const interval = Math.max(1, Number(kind===4 ? rule.month_interval : rule.year_interval)||1);
    const period = kind===4 ? months : years;
    valid = day.getDate()===monthDay && period%interval===0 && within(period/interval) &&
      (kind===4 || day.getMonth()+1===(Number(rule.month)||first.getMonth()+1));
  } else valid = elapsed === 0;
  return valid ? when : 0;
}

export function taskViews(state, team, user) {
  const parts = new Map();
  for (const row of Object.values(state.rows)) {
    const taskID = row.data.task_id;
    if (row.team !== team || row.removed || !taskID) continue;
    if (!parts.has(taskID)) parts.set(taskID, []);
    parts.get(taskID).push(row);
  }
  return list(state, team, T.task).map(row => taskView(row, parts.get(row.uid) || [], user));
}

function taskView(row, parts, user) {
  const one = (table, predicate = () => true) => parts.find(part => part.table === table && predicate(part.data));
  const schedule = one(T.schedule);
  const repeat = one(T.repeat);
  const alert = one(T.alarm, data => Number(data.user_id) === user);
  const start = Number(schedule?.data.start_at)||0;
  const done = time => {
    const matches = parts.filter(part => part.table === T.check && Number(part.data.user_id) === user &&
      Number(part.data.status) === 1)
      .sort((a,b) => Number(b.data.check_at)-Number(a.data.check_at));
    return repeatKind(repeat?.data || {}) ? matches.find(part => Number(part.data.start_at) === Number(time)) : matches[0];
  };
  return { row, parts, schedule, repeat, alert, start, done,
    end:Number(schedule?.data.end_at)||0, allDay:Number(schedule?.data.is_all_day)===1,
    at:day => occurs(start, repeat?.data || {}, day),
    next:day => {
      const rule = repeat?.data || {};
      if (!repeatKind(rule) || !start || start >= localDay(day).getTime()/1000) return start;
      for (let i=0;i<740;i++) {
        const time = occurs(start, rule, addDays(day,i));
        if (time) return time;
        if (Number(rule.repeat_end)>0 && addDays(day,i).getTime()/1000 > Number(rule.repeat_end)) break;
      }
      return start;
    },
    remark:one(T.detail, data => Number(data.type)===2)?.data.content || '',
    review:one(T.detail, data => Number(data.type)===1)?.data.content || '',
  };
}

export const readTask = (state, row, user) => taskView(row,
  Object.values(state.rows).filter(part => part.team===row.team && !part.removed && part.data.task_id===row.uid), user);

function ruleFor(kind, start, end) {
  const first = new Date(start*1000), weekday = first.getDay();
  const rule = { repeat_start:start, repeat_end:end, repeat_count:0, status:0,
    repeat_start_day:0, repeat_start_week:0, repeat_start_month:0, repeat_start_year:0,
    day_interval:1, week_interval:1, month_interval:1, year_interval:1, month:0, day:0, weekday:'0000000' };
  if (kind===1) Object.assign(rule, { repeat_start_day:localDay(first).getTime()/1000, day_interval:86400 });
  if (kind===2 || kind===3) Object.assign(rule, { repeat_start_week:addDays(first,-weekday).getTime()/1000, week_interval:604800,
    weekday:kind===3?'0234560':Array.from({length:7},(_,i)=>i===weekday?i+1:0).join('') });
  if (kind===4 || kind===5) Object.assign(rule, { repeat_start_year:first.getFullYear(), day:first.getDate(),
    [kind===4?'repeat_start_month':'month']:first.getMonth()+1 });
  return rule;
}

export function taskSnapshot(state, row, user) {
  const task = readTask(state,row,user);
  const data = row.data;
  const children=task.parts.filter(part=>part.table===T.subtask).sort((a,b)=>(a.data.sequence||0)-(b.data.sequence||0));
  const personal=state.spaces.some(space=>Number(space.id)===row.team&&Number(space.type)===1);
  const mine=part=>Number(part.data.user_id)===user && Number(part.data.status)===1;
  return { name:data.name, rank:Number(data.rank)||1, place:data.position_id||'', project:data.project_id||'',
    start:task.start, end:task.end, allDay:task.allDay, repeat:repeatKind(task.repeat?.data||{}),
    repeatEnd:Number(task.repeat?.data.repeat_end)||0, alert:Number(task.alert?.data.alert_time??-1),
    reminderMode:task.alert?.data.reminder_mode||'both', remark:task.remark, review:task.review,
    children:children.map(part=>part.data.name),
    tags:task.parts.filter(part=>part.table===T.taskTag).map(part=>part.data.tag_name).filter(Boolean).sort(),
    ...(personal?{
      checks:task.parts.filter(part=>part.table===T.check&&mine(part)).map(part=>[Number(part.data.start_at)||0,Number(part.data.check_at)||0]),
      completedChildren:children.flatMap((child,index)=>task.parts.some(part=>part.table===T.subcheck&&mine(part)&&
        part.data.child_task_id===child.uid)?[index]:[]),
    }:{}),
    attachments:filesOf(state,row).map(file=>file.uid).sort() };
}

export function saveTask(state, user, team, uid, edit, personal) {
  const existing = get(state,team,T.task,uid);
  const view = existing && readTask(state,existing,user);
  const titles = edit.name?.trim();
  if (!titles || edit.end < edit.start) throw new Error('请填写任务名称和有效的计划时间');
  const row = put(state,user,team,T.task,uid,{ name:titles, rank:Number(edit.rank)||1,
    privacy:existing?.data.privacy ?? (team===personal ? 6720 : 6728), project_id:edit.project||'', position_id:edit.place||'' });
  if (!existing) put(state,user,team,T.assignee,id(T.assignee),{ task_id:uid, role:7680, sequence:0, status:0 });
  const scheduleID = view?.schedule?.uid || id(T.schedule);
  put(state,user,team,T.schedule,scheduleID,{ task_id:uid, start_at:edit.start, end_at:edit.end,
    is_all_day:edit.allDay?1:0, is_repeat:edit.start&&edit.repeat?1:0 });
  if (edit.start && edit.repeat) {
    const oldRule = view?.repeat;
    if (!oldRule || view.start!==edit.start || repeatKind(oldRule.data)!==edit.repeat ||
        Number(oldRule.data.repeat_end||0)!==Number(edit.repeatEnd||0)) {
      put(state,user,team,T.repeat,oldRule?.uid || id(T.repeat),
        { task_id:uid, schedule_id:scheduleID, ...ruleFor(edit.repeat, edit.start, Number(edit.repeatEnd)||0) });
    }
  } else if (view?.repeat) remove(state,view.repeat);
  if (edit.start && edit.alert>=0) put(state,user,team,T.alarm,view?.alert?.uid || id(T.alarm),
    { task_id:uid, schedule_id:scheduleID, alert_time:edit.alert, reminder_mode:edit.reminderMode || 'both' });
  else if (view?.alert) remove(state,view.alert);
  for (const [type,value] of [[1,edit.review],[2,edit.remark]]) {
    if (value===undefined) continue;
    const previous = view?.parts.find(part=>part.table===T.detail && Number(part.data.type)===type);
    if (value) put(state,user,team,T.detail,previous?.uid || id(T.detail),{ task_id:uid, type, content:value });
    else if (previous) remove(state,previous);
  }
  if (Array.isArray(edit.children)) {
    const remaining = view?.parts.filter(part=>part.table===T.subtask) || [];
    edit.children.forEach((name,sequence) => {
      const index=remaining.findIndex(part=>part.data.name===name);
      const previous=index>=0?remaining.splice(index,1)[0]:null;
      put(state,user,team,T.subtask,previous?.uid || id(T.subtask),{ task_id:uid, name, sequence });
    });
    for (const part of remaining) {
      remove(state,part);
      for (const related of view.parts) if (related.table===T.subcheck&&related.data.child_task_id===part.uid) remove(state,related);
    }
  }
  if (Array.isArray(edit.tags)) {
    const catalog=new Set(list(state,team,T.tag).map(tag=>tag.data.name));
    const mappings=new Map(view?.parts.filter(part=>part.table===T.taskTag).map(part=>[part.data.tag_name,part]));
    for (const name of new Set(edit.tags)) {
      if (!catalog.has(name)) {
        put(state,user,team,T.tag,id(T.tag),{name});
        catalog.add(name);
      }
      if (!mappings.delete(name)) put(state,user,team,T.taskTag,id(T.taskTag),{task_id:uid,tag_name:name});
    }
    for (const part of mappings.values()) remove(state,part);
  }
  return row;
}

export function restoreTaskChecks(state,user,row,snapshot) {
  const task=readTask(state,row,user);
  if (Array.isArray(snapshot.checks)) {
    for(const part of task.parts) if(part.table===T.check&&Number(part.data.user_id)===user) remove(state,part);
    for(const [start,checked] of snapshot.checks) put(state,user,row.team,T.check,id(T.check),
      {task_id:row.uid,schedule_id:task.schedule.uid,start_at:start,begin_time:start,check_at:checked,
        cost_time:start?Math.max(0,checked-start):0,status:1,role:7680});
  }
  if (Array.isArray(snapshot.completedChildren)) {
    const children=task.parts.filter(part=>part.table===T.subtask).sort((a,b)=>(a.data.sequence||0)-(b.data.sequence||0));
    for(const [index,child] of children.entries()) {
      const previous=task.parts.find(part=>part.table===T.subcheck&&Number(part.data.user_id)===user&&part.data.child_task_id===child.uid);
      if(snapshot.completedChildren.includes(index)) put(state,user,row.team,T.subcheck,previous?.uid||id(T.subcheck),
        {task_id:row.uid,child_task_id:child.uid,status:1});
      else if(previous)remove(state,previous);
    }
  }
}

export function toggleTask(state, user, row, time) {
  const current = get(state,row.team,T.task,row.uid);
  if (!current || current.removed) return;
  const task = readTask(state,current,user);
  const done = task.done(time);
  if (done) remove(state,done);
  else {
    const now = Math.floor(Date.now()/1000);
    if (!task.schedule) return;
    put(state,user,row.team,T.check,id(T.check),{ task_id:row.uid, schedule_id:task.schedule.uid,
      start_at:time, begin_time:time, check_at:now, cost_time:time?Math.max(0,now-time):0, status:1, role:7680 });
  }
}

const unit = 10n ** 18n;
export function amount(value) {
  const match = /^(\d{1,30})(?:\.(\d{1,18}))?$/.exec(String(value).trim());
  if (!match) throw new Error('请输入金额，最多 30 位整数和 18 位小数');
  return BigInt(match[1]) * unit + BigInt((match[2] || '').padEnd(18,'0'));
}
export function decimal(value) {
  const cents = (value % unit).toString().padStart(18,'0').replace(/0+$/,'').padEnd(2,'0');
  return (value / unit).toString() + '.' + cents;
}
export const currency = row => /^[A-Z]{3}$/.test(row.data.currency) ? row.data.currency : 'CNY';
export const money = (value,code='CNY') => decimal(value) + (code==='CNY'?' 元':' '+code);
export const include = (row, field) => row.data[field] === undefined || Number(row.data[field]) !== 0;

export function billSnapshot(state, row) {
  const { name,date,type,amount:total,channel,party,remark,location,latitude,longitude }=row.data;
  return { name,date,type,amount:total,channel,party,remark:remark||'',location:location||'',latitude:latitude||'',longitude:longitude||'',
    currency:currency(row), include_in_totals:include(row,'include_in_totals')?1:0,
    include_in_party_stats:include(row,'include_in_party_stats')?1:0,
    attachments:filesOf(state,row).map(file=>file.uid).sort() };
}

export function saveBill(state,user,team,uid,edit) {
  if (!edit.name?.trim() || !edit.party?.trim() || !edit.channel?.trim() || !/^\d{4}-\d{2}-\d{2}$/.test(edit.date) ||
      !Object.hasOwn(billTypes,edit.type)||edit.channel.trim().length>100||edit.party.trim().length>100) {
    throw new Error('请填写日期、事项、途径和收支方，途径和收支方上限 100 字');
  }
  const patch = { ...edit, amount:decimal(amount(edit.amount)) };
  delete patch.attachments;
  const row=put(state,user,team,T.bill,uid,patch);
  for (const [kind,name] of [['channel',edit.channel.trim()],['party',edit.party.trim()]]) {
    if (!list(state,team,T.option).some(option=>option.data.kind===kind && option.data.name===name))
      put(state,user,team,T.option,id(T.option),{ kind,name,status:0 });
  }
  return row;
}

const versionTable = row => row.table===T.task?T.taskHistory:T.billHistory;
export const versions = (state,row) => related(state,row,versionTable(row),'parent_id')
  .sort((a,b)=>Number(b.data.version_at)-Number(a.data.version_at));
export function captureVersion(state,user,row,action='保存') {
  const previous=versions(state,row)[0];
  const snapshot=JSON.stringify(row.table===T.task?taskSnapshot(state,row,user):billSnapshot(state,row));
  if (previous?.data.snapshot===snapshot && previous.data.action===action) return;
  const table=versionTable(row);
  put(state,user,row.team,table,id(table),{ parent_id:row.uid,snapshot,action,
    version_at:Math.max(Date.now(),(Number(previous?.data.version_at)||0)+1) });
}

export const noteTitle = row => row.data.title || String(row.data.name || '').trim().split('\n')[0] || '未命名便签';
export const customNotebook = section => section==='diary'||section==='info';

// The existing private note protocol preserves notebook_section as a string.
// Store the folder kind and parent here so that both travel with the note.
function notebookLocation(row) {
  const value=String(row.data.notebook_section||'quick');
  const [section,kind,parent='']=value.split(':');
  return customNotebook(section)?{section,folder:kind==='folder',parent}:{section:value,folder:false,parent:''};
}
export const noteSection = row => notebookLocation(row).section;
export const isNoteFolder = row => notebookLocation(row).folder;
export const noteParent = row => notebookLocation(row).parent;
export const documentSection = (section,parent='') => customNotebook(section)&&parent ? section+':doc:'+parent : section;

export function noteFolders(state,team,section) {
  if (!customNotebook(section)) return [];
  const byParent=Map.groupBy(list(state,team,T.note).filter(row=>noteSection(row)===section&&isNoteFolder(row)),noteParent);
  const folders=[];
  function visit(parent,path,depth) {
    if (depth>3) return;
    const children=(byParent.get(parent)||[]).sort((a,b)=>noteTitle(a).localeCompare(noteTitle(b),'zh-CN'));
    for (const row of children) {
      const name=noteTitle(row);
      const next=[...path,name];
      folders.push({ uid:row.uid,parent,depth,name,path:next.join(' / ') });
      visit(row.uid,next,depth+1);
    }
  }
  visit('',[],1);
  return folders;
}

export function saveNoteFolder(state,account,team,section,uid,name,parent='') {
  const title=String(name||'').trim();
  if (!customNotebook(section)||!title||title.length>100) throw new Error('请输入 1 到 100 字的目录名称');
  const folders=noteFolders(state,team,section);
  const target=folders.find(folder=>folder.uid===parent);
  if (parent&&!target) throw new Error('上级目录已失效，请重新选择');
  if (target?.depth===3) throw new Error('目录最多三层');
  if (folders.some(folder=>folder.parent===parent&&folder.name===title)) throw new Error('同一层已有这个目录');
  put(state,account,team,T.note,uid,{name:title,title,conversation_version:1,attachments:'[]',status:0,
    notebook_section:section+':folder:'+parent});
}

export function noteEntries(state, row) {
  const entries = related(state,row,T.entry,'note_id');
  if (!Number(row.data.conversation_version)) {
    const at = utcDate(row.data.created_at).getTime() || row.edited;
    if (row.data.name) entries.push({ legacy:'text', data:{ kind:'text', content:row.data.name, entry_at:at } });
    try {
      const media=JSON.parse(row.data.attachments || '[]');
      for (const [index,file] of media.entries()) {
        entries.push({ legacy:'media-'+file.id, data:{ ...file, media_id:file.id, client_media_id:'remote-'+file.id, entry_at:at+index+1 } });
      }
    } catch { /* Older records can contain missing attachment metadata. */ }
  }
  return entries.sort((a,b)=>Number(a.data.entry_at)-Number(b.data.entry_at) || String(a.uid).localeCompare(String(b.uid)));
}
