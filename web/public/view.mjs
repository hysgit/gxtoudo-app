import { icon } from './icons.mjs';
import { T, addDays, dateKey, dayText, clock, utcDate, whenText, amount, money, currency, include,
  priorities, billTypes, list, noteTitle, noteSection, noteEntries, taskViews, filesOf } from './domain.mjs';

export const h = input => String(input ?? '').replace(/[&<>"']/g, c=>({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
export const pages = { tasks:'任务', timeline:'时间轴', bills:'记账', notes:'便签', ai:'AI 对话', trash:'回收站' };
export const sections = { quick:'速记', essence:'精髓', core:'内核' };
const weekdays=['日','一','二','三','四','五','六'];
const financeIcon = (type, code) => `<span class="currency-symbol ${type}">${h(code==='CNY'?'¥':code)}</span>`;
export const action = (label, act, glyph, tone='secondary') => `<button type="button" class="button ${tone}" data-act="${act}">${glyph?icon(glyph,17):''}${label}</button>`;
const tile = (label, act, glyph) => `<button type="button" class="icon-button" title="${label}" aria-label="${label}" data-act="${act}">${icon(glyph,17)}</button>`;
const monthFormat = value => /^\d{4}-\d\d$/.test(value) ? `${value.slice(0,4)}年${Number(value.slice(5))}月` : value;
const planned = task => !task.when?'未安排':`${dayText(new Date(task.when*1000))} ${task.allDay?'全天':clock(new Date(task.when*1000))}`;
const empty = (glyph,title,detail,button='') => `<div class="empty"><span class="empty-icon">${icon(glyph,26)}</span>
  <strong>${title}</strong>${detail?`<p>${detail}</p>`:''}${button}</div>`;
const press = selected => `aria-pressed="${selected}"`;
const numeric = (row,field) => Number(row.data[field])||0;

function header(ctx) {
  const page=ctx.page, searchable=page!=='ai';
  return `<header class="topbar">
    <div class="breadcrumb"><span class="path-home">工作台</span>${icon('right',13)}<strong>${pages[page]}</strong></div>
    <div class="top-actions">
      ${searchable?`<label class="searchbar">${icon('search',17)}<input id="search" type="search" value="${h(ctx.query)}"
        placeholder="${page==='notes'?'搜索便签':'搜索当前页'}" aria-label="搜索当前页" autocomplete="off"><kbd>Ctrl K</kbd></label>`:''}
      <div class="account-avatar" title="${h(ctx.account.name)}">${h(ctx.account.name.slice(0,1))}</div>
    </div>
  </header>`;
}

function sidebar(ctx) {
  const space=ctx.state.spaces.find(space=>Number(space.id)===ctx.team);
  return `<aside class="sidebar">
    <a class="brand" href="#tasks"><span class="brand-mark">${icon('logo',30)}</span><strong>高效 Todo</strong></a>
    <label class="space-picker"><span class="space-mark">${icon('grid',19)}</span><span class="space-copy">
      <small>当前空间</small><strong>${h(space?.name || '个人空间')}</strong></span>${icon('down',15)}
      <select aria-label="切换空间" id="space">${ctx.state.spaces.map(space=>
        `<option value="${Number(space.id)}" ${Number(space.id)===ctx.team?'selected':''}>${h(space.name)}</option>`).join('')}</select>
    </label>
    <nav aria-label="主菜单" class="navigation">
      ${['tasks','timeline','bills','notes','ai'].map(page=>`<a href="#${page}" ${ctx.page===page?'aria-current="page"':''}>${icon(page,19)}<span>${pages[page]}</span></a>`).join('')}
    </nav>
    <div class="sidebar-bottom">
      <a class="recycle" href="#trash" ${ctx.page==='trash'?'aria-current="page"':''}>${icon('trash',18)}<span>回收站</span></a>
      <div class="sync-card"><span class="sync-dot ${ctx.syncFailed?'sync-error':''}"></span><div><strong id="sync-status">${h(ctx.status)}</strong>
        <small>${h(ctx.account.name)}</small></div>${tile('立即同步','sync','sync')}</div>
      <button class="logout" data-act="logout">${icon('exit',17)}<span>退出登录</span></button>
    </div>
  </aside>`;
}

function pageHeading(title, subtitle, commands='') {
  return `<div class="page-heading"><div><h1>${title}</h1>${subtitle?`<p>${subtitle}</p>`:''}</div><div class="page-actions">${commands}</div></div>`;
}

function week(ctx, allTasks) {
  const today=new Date(), focus=ctx.week;
  const first=addDays(focus,-((focus.getDay()+6)%7));
  const last=addDays(first,6);
  const days=Array.from({length:7},(_,index)=>{
    const date=addDays(first,index), value=dateKey(date);
    const planned=allTasks.reduce((count,task)=>count+Number(Boolean(task.at(date))),0);
    return `<button class="week-day ${value===dateKey(today)?'day-today':''}" data-act="day" data-date="${value}" ${press(ctx.day===value)}
      aria-label="${dayText(date)} 周${weekdays[date.getDay()]}，${planned} 项任务">
      <span>周${weekdays[date.getDay()]}</span><strong>${date.getDate()}</strong><i class="${planned?'has-tasks':''}"></i>
    </button>`;
  }).join('');
  return `<section class="week-strip" aria-label="周日历">
    <div class="week-heading"><div><small>${focus.getFullYear()} 年</small><div>${dayText(first)} <span>–</span> ${dayText(last)}</div></div>
      <div class="week-controls"><button type="button" data-act="today">今天</button>${tile('上一周','previous-week','left')}${tile('下一周','next-week','right')}</div></div>
    <div class="week-grid">${days}</div>
  </section>`;
}

export function taskRows(ctx) {
  const tasks=taskViews(ctx.state,ctx.team,ctx.account.id);
  const now=new Date();
  const filtered=ctx.day ? new Date(ctx.day+'T00:00:00') : null;
  const entries=tasks.map(task=>{
    const when=filtered?task.at(filtered):task.next(now);
    return { ...task, when, complete:task.done(when) };
  }).filter(task=>(!filtered||task.when) &&
    `${task.row.data.name} ${task.remark}`.toLocaleLowerCase().includes(ctx.query.toLocaleLowerCase()));
  entries.sort((a,b)=> Number(!!a.complete)-Number(!!b.complete) ||
    (a.complete&&b.complete ? numeric(b.complete,'check_at')-numeric(a.complete,'check_at') :
      (a.when||Infinity)-(b.when||Infinity) || b.row.edited-a.row.edited));
  return { tasks,entries };
}

function taskRow(task, selection) {
  const row=task.row, done=!!task.complete, rank=Math.max(1,Math.min(4,Number(row.data.rank)||1));
  const selected=selection===row.uid;
  return `<li class="task-row ${selected?'selected':''} ${done?'completed':''}">
    <button type="button" class="task-check" data-act="complete" data-id="${h(row.uid)}" data-time="${task.when}"
      aria-label="${done?'恢复待完成':'标记完成'} ${h(row.data.name)}" ${press(done)}>${done?icon('check',15):''}</button>
    <button type="button" class="row-main" data-act="select" data-id="${h(row.uid)}">
      <span class="task-name">${h(row.data.name)}</span>
      <span class="task-date">${icon('clock',15)}${planned(task)}</span>
      <span class="priority priority-${rank}"><i></i>${priorities[rank-1]}</span>
    </button>
    <button type="button" class="icon-button row-open" data-act="edit" data-id="${h(row.uid)}" aria-label="编辑任务" title="编辑任务">${icon('more',18)}</button>
  </li>`;
}

function attachmentRow(row) {
  const data=row.data;
  const type=data.kind==='image'?'图片':data.kind==='audio'?'语音':'文件';
  return `<button type="button" class="file-chip" data-act="open-media" data-id="${h(row.uid||row.legacy)}">${icon(data.kind==='image'?'image':data.kind==='audio'?'mic':'file',16)}${h(data.media_name||type)}</button>`;
}

function taskDetail(ctx, task) {
  if (!task) return `<aside class="inspector placeholder-inspector">
    <span class="eyebrow">任务详情</span>${empty('tasks','选择一条任务','查看计划、提醒和备注。')}</aside>`;
  const row=task.row, at=task.when?new Date(task.when*1000):null;
  const subtasks=task.parts.filter(part=>part.table===T.subtask);
  const attachments=filesOf(ctx.state,row);
  const alarm=Number(task.alert?.data.alert_time??-1);
  const reminder=alarm<0?'无提醒':alarm===0?'开始时':`提前 ${alarm/60} 分钟`;
  return `<aside class="inspector"><div class="inspector-top"><span class="eyebrow">任务详情</span>${tile('关闭详情','clear-selection','close')}</div>
    <h2>${h(row.data.name)}</h2><span class="status-pill ${task.complete?'is-done':''}">${task.complete?'已完成':'待完成'}</span>
    <dl class="detail-meta"><div><dt>计划</dt><dd>${at?planned(task):'未安排'}</dd></div><div><dt>提醒</dt><dd>${reminder}</dd></div>
    <div><dt>优先级</dt><dd>${priorities[Math.max(0,Math.min(3,(Number(row.data.rank)||1)-1))]}</dd></div></dl>
    ${task.remark?`<div class="detail-section"><h3>备注</h3><p>${h(task.remark)}</p></div>`:''}
    ${subtasks.length?`<div class="detail-section"><h3>子任务</h3><ul class="compact-list">${subtasks.map(item=>`<li>${h(item.data.name)}</li>`).join('')}</ul></div>`:''}
    ${attachments.length?`<div class="detail-section"><h3>附件</h3><div class="files">${attachments.map(attachmentRow).join('')}</div></div>`:''}
    <div class="inspector-actions">${action('编辑','edit','edit','primary')}${action('历史版本','versions','history')}${tile('移到回收站','delete','trash')}</div>
  </aside>`;
}

function tasksPage(ctx) {
  const {tasks,entries}=taskRows(ctx);
  const open=entries.filter(task=>!task.complete), completed=entries.filter(task=>task.complete);
  const shown=ctx.filter==='open'?open:ctx.filter==='done'?completed:entries;
  const selection=entries.find(task=>task.row.uid===ctx.selected);
  const title=ctx.page==='timeline'?'时间轴':'任务';
  const selectedTitle=ctx.day?dayText(new Date(ctx.day+'T00:00:00'))+'的安排':'任务列表';
  return pageHeading(title,`<span class="subtle-date">${dayText(new Date())} · 周${weekdays[new Date().getDay()]}</span>`,action('新建任务','new','plus','primary')) +
    `<div class="work-grid ${selection?'has-selection':''}"><div class="work-main">${week(ctx,tasks)}
      <section class="content-card tasks-card"><div class="section-head"><h2>${selectedTitle}</h2>
      ${ctx.day&&ctx.page==='tasks'?action('查看全部','clear-day',null,'ghost'):''}</div>
      <div class="list-toolbar" aria-label="任务状态">${[['all','全部',entries.length],['open','待完成',open.length],['done','已完成',completed.length]]
        .map(([key,label,count])=>`<button type="button" class="filter-tab" data-act="task-filter" data-filter="${key}" ${press(ctx.filter===key)}>${label}<span>${count}</span></button>`).join('')}</div>
      ${shown.length?`<ul class="task-list">${shown.map(task=>taskRow(task,ctx.selected)).join('')}</ul>`:
        empty('tasks',ctx.query?'没有找到相关任务':'这里还没有任务',ctx.query?'试试任务名称中的其他关键词。':'',ctx.query?'':action('新建任务','new','plus','secondary'))}
      </section></div>${taskDetail(ctx,selection)}</div>`;
}

export function billRows(ctx) {
  const all=list(ctx.state,ctx.team,T.bill);
  const month=all.filter(row=>String(row.data.date).startsWith(ctx.month+'-'));
  month.sort((a,b)=>String(b.data.date).localeCompare(a.data.date)||b.edited-a.edited);
  const groups=new Map(), sums=new Map();
  for (const row of month) {
    if (row.data.type!=='income' && row.data.type!=='expense') continue;
    const type=row.data.type, code=currency(row), key=JSON.stringify([code,row.data.party]);
    let total;
    try { total=amount(row.data.amount); } catch { continue; }
    if (include(row,'include_in_totals')) {
      if (!sums.has(code)) sums.set(code,{ code, expense:0n, income:0n });
      sums.get(code)[type]+=total;
    }
    if (include(row,'include_in_party_stats')) {
      if (!groups.has(key)) groups.set(key,{ code, party:row.data.party||'', income:0n, expense:0n });
      groups.get(key)[type]+=total;
    }
  }
  if (!sums.size) sums.set('CNY',{ code:'CNY',expense:0n,income:0n });
  const rows=month.filter(row=> `${row.data.name} ${row.data.channel} ${row.data.party} ${row.data.remark??''}`.toLocaleLowerCase().includes(ctx.query.toLocaleLowerCase()) &&
    (!ctx.billFilter || (currency(row)===ctx.billFilter.code && row.data.type===ctx.billFilter.type &&
      row.data.party===ctx.billFilter.party && include(row,'include_in_party_stats'))));
  return { all,rows,groups,sums };
}

function billDetail(ctx,row) {
  if (!row) return '';
  const data=row.data;
  return `<aside class="inspector"><div class="inspector-top"><span class="eyebrow">账单详情</span>${tile('关闭详情','clear-selection','close')}</div>
    <h2>${h(data.name)}</h2><span class="bill-detail-amount ${h(data.type)}">${h(data.amount)} ${currency(row)==='CNY'?'元':currency(row)}</span>
    <dl class="detail-meta">${[['日期',data.date],['类型',billTypes[data.type]],['途径',data.channel],['收支方',data.party],['地点',data.location]]
      .filter(([,value])=>value).map(([label,value])=>`<div><dt>${label}</dt><dd>${h(value)}</dd></div>`).join('')}</dl>
    ${data.remark?`<div class="detail-section"><h3>备注</h3><p>${h(data.remark)}</p></div>`:''}
    <div class="files">${filesOf(ctx.state,row).map(attachmentRow).join('')}</div>
    <div class="inspector-actions">${action('编辑','edit','edit','primary')}${action('历史版本','versions','history')}${tile('移到回收站','delete','trash')}</div>
    </aside>`;
}

function billsPage(ctx) {
  const { all,rows,groups,sums }=billRows(ctx);
  const now=dateKey(new Date()).slice(0,7);
  const months=[...new Set(all.map(row=>String(row.data.date).slice(0,7)).filter(month=>/^\d{4}-\d\d$/.test(month) && month!==now))].sort().reverse();
  const years=[...new Set(months.map(month=>month.slice(0,4)))];
  const current=ctx.month===now;
  const selection=rows.find(row=>row.uid===ctx.selected);
  const filters=`<div class="segment"><button data-act="current-month" ${press(current&&!ctx.archive)}>本月</button><button data-act="archive" ${press(ctx.archive)}>已归档</button></div>`;
  const archive=ctx.archive?`<div class="archive-months">${years.length?years.map(year=>
    `<details ${ctx.month.startsWith(year)?'open':''}><summary>${year} 年</summary><div>${months.filter(month=>month.startsWith(year))
      .map(month=>`<button data-act="month" data-month="${month}" ${press(month===ctx.month)}>${Number(month.slice(5))}月</button>`).join('')}</div></details>`).join(''):
      '<p>暂无已归档账单。</p>'}</div>`:'';
  const totals=[...sums.values()].map(sum=>`<div class="bill-totals">
    ${['expense','income'].map(type=>`<div class="metric ${type}">${financeIcon(type,sum.code)}<div><small>${type==='expense'?'总支出':'总收入'}</small><strong>${money(sum[type],sum.code)}</strong></div></div>`).join('')}
  </div>`).join('');
  const statRows=[...groups.values()].map(group=>`<tr><th scope="row">${h(group.party||'未填写')}</th>${['expense','income'].map(type=>{
    const selected=ctx.billFilter?.type===type && ctx.billFilter.code===group.code && ctx.billFilter.party===group.party;
    return `<td><button class="amount-link ${type}" data-act="bill-filter" data-type="${type}" data-code="${group.code}" data-party="${h(group.party)}"
      ${press(selected)}>${money(group[type],group.code)}</button></td>`;
  }).join('')}</tr>`).join('');
  const detailRows=rows.map(row=>`<tr class="${row.uid===ctx.selected?'selected':''}">
      <td>${h(row.data.date)}</td><td><span class="type-tag ${h(row.data.type)}">${h(billTypes[row.data.type])}</span></td>
      <td class="amount ${h(row.data.type)}">${h(row.data.amount)} ${currency(row)==='CNY'?'元':currency(row)}</td>
      <td>${h(row.data.channel)}</td><td>${h(row.data.party)}</td><td><button data-act="select" data-id="${h(row.uid)}" class="text-button">${h(row.data.name)}</button></td></tr>`).join('');
  return pageHeading('记账',h(monthFormat(ctx.month)),action('新建账单','new','plus','primary'))+
    `<div class="work-grid ledger-grid ${selection?'has-selection':''}"><div class="work-main">
      ${filters}${archive}${totals}
      ${statRows?`<section class="content-card ledger-card"><div class="section-head"><h2>收支统计</h2></div>
        <div class="table-scroll"><table class="ledger-table stats-table"><thead><tr><th>支出收入方</th><th>支出汇总</th><th>收入汇总</th></tr></thead><tbody>${statRows}</tbody></table></div></section>`:''}
      <section class="content-card ledger-card"><div class="section-head"><h2>账单明细</h2>
        ${ctx.billFilter?action(h(ctx.billFilter.party)+' · '+billTypes[ctx.billFilter.type],'bill-unfilter','close','filter-chip'):''}</div>
      ${detailRows?`<div class="table-scroll"><table class="ledger-table"><thead><tr><th>日期</th><th>类型</th><th>金额</th><th>途径</th><th>支出收入方</th><th>事项</th></tr></thead><tbody>${detailRows}</tbody></table></div>`:
        empty('bills',ctx.query||ctx.billFilter?'没有匹配的账单':'本月还没有账单','')}</section></div>${billDetail(ctx,selection)}</div>`;
}

export function noteRows(ctx) {
  return list(ctx.state,ctx.team,T.note).filter(row=>noteSection(row)===ctx.noteSection)
    .filter(row=>!ctx.query || (noteTitle(row)+' '+noteEntries(ctx.state,row).map(entry=>entry.data.content||'').join(' ')).toLocaleLowerCase().includes(ctx.query.toLocaleLowerCase()))
    .sort((a,b)=>utcDate(b.data.created_at)-utcDate(a.data.created_at)||b.edited-a.edited);
}

function noteButton(row,ctx,document=false) {
  const at=utcDate(row.data.created_at);
  return `<button class="note-tile ${ctx.selected===row.uid?'selected':''}" data-act="select" data-id="${h(row.uid)}">
    <span class="note-symbol">${icon('notes',18)}</span><span><strong>${h((document&&Number.isFinite(at.getTime())?dateKey(at)+' ':'')+noteTitle(row))}</strong>
    ${document?'':`<small>${h(whenText(at))}</small>`}</span>${icon('right',16)}</button>`;
}

function notesPage(ctx) {
  const rows=noteRows(ctx);
  const selected=rows.find(row=>row.uid===ctx.selected);
  const docs=ctx.noteSection!=='quick';
  const groups=Map.groupBy(rows,row=>whenText(utcDate(row.data.created_at)).slice(0,7) || '日期未知');
  const years=Map.groupBy([...groups.keys()],month=>month.slice(0,4));
  const entries=selected?noteEntries(ctx.state,selected):[];
  const listMarkup=docs?[...years].map(([year,months])=>`<details class="note-year" open><summary>${h(year)} 年</summary>${months.map(month=>
    `<details class="note-month" open><summary>${/^\d{4}-\d\d$/.test(month)?Number(month.slice(5))+' 月':h(month)}</summary>
    ${groups.get(month).map(row=>noteButton(row,ctx,true)).join('')}</details>`).join('')}</details>`).join(''):
    rows.map(row=>noteButton(row,ctx)).join('');
  return pageHeading('便签','',action(docs?'新建记事本':'新建速记','new','plus','primary'))+
    `<div class="segment note-segments">${Object.entries(sections).map(([section,label])=>`<button data-act="note-section" data-section="${section}" ${press(ctx.noteSection===section)}>${label}</button>`).join('')}</div>
      <div class="notes-grid ${selected?'has-selection':''}"><section class="content-card notes-list" aria-label="便签标题列表">
      ${listMarkup||empty('notes','暂时没有便签','')}</section>
      <section class="content-card note-content">${selected?`<div class="note-head"><div><h2>${h(noteTitle(selected))}</h2><small>${h(whenText(utcDate(selected.data.created_at)))}</small></div>
      <div class="inline-actions">${tile(docs?'编辑文档':'修改标题','edit','edit')}${tile('删除便签','delete','trash')}</div></div>
      <div id="note-messages" class="${docs?'document-body':'messages'}">
        ${entries.map(entry=>`<div class="note-entry ${entry.data.kind==='text'?'note-text':''}">
          ${docs?'':`<time>${h(whenText(Number(entry.data.entry_at)))}</time>`}
          ${entry.data.kind==='text'?`<p>${h(entry.data.content)}</p>`:`<div data-preview="${h(entry.uid||entry.legacy)}">${attachmentRow(entry)}</div>`}
          ${!docs&&entry.uid?`<button class="icon-button entry-remove" data-act="remove-entry" data-id="${h(entry.uid)}" title="删除这一条" aria-label="删除这一条">${icon('close',15)}</button>`:''}</div>`).join('')}
      </div>
      ${docs?'':`<form id="note-send" class="composer"><textarea name="text" rows="2" maxlength="60000" placeholder="写下这一刻…" aria-label="速记内容">${h(ctx.noteDraft)}</textarea>
        <div class="composer-tools"><label class="small-action">${icon('image',17)}图片或音频<input type="file" id="note-files" multiple accept="image/*,audio/*"></label>
        ${action(ctx.recording?'停止录音':'录音','record','mic','ghost')}${ctx.canDictate?action('语音输入','dictate-note','mic','ghost'):''}
        <button class="button primary push-right" type="submit">${icon('send',16)}发送</button></div></form>`}`:
        empty('notes','打开一条便签','从左侧选择，或创建一条新的记录。')}</section></div>`;
}

export function markdown(text) {
  const inline = value => h(value).replace(/`([^`]+)`/g,'<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/\*([^*]+)\*/g,'<em>$1</em>');
  const lines=String(text||'').replaceAll('\r','').split('\n');
  const output=[];
  for (let i=0;i<lines.length;i++) {
    const line=lines[i];
    if (line.startsWith('```')) {
      const block=[];
      while (++i<lines.length && !lines[i].startsWith('```')) block.push(lines[i]);
      output.push('<pre><code>'+h(block.join('\n'))+'</code></pre>');
    } else if (/^#{1,6} /.test(line)) {
      const match=/^(#+) (.*)$/.exec(line), size=Math.min(5,match[1].length+2);
      output.push(`<h${size}>${inline(match[2])}</h${size}>`);
    } else if (line.includes('|') && /^\s*\|?\s*:?-{3,}/.test(lines[i+1]||'')) {
      const cells=value=>value.trim().replace(/^\||\|$/g,'').split('|').map(cell=>inline(cell.trim()));
      const header=cells(line), body=[];
      i++;
      while (lines[i+1]?.includes('|') && lines[i+1].trim()) body.push(cells(lines[++i]));
      output.push('<div class="table-scroll"><table><thead><tr>'+header.map(cell=>'<th>'+cell+'</th>').join('')+'</tr></thead><tbody>'+
        body.map(row=>'<tr>'+row.map(cell=>'<td>'+cell+'</td>').join('')+'</tr>').join('')+'</tbody></table></div>');
    } else if (/^\s*([-*]|\d+\.) /.test(line)) {
      const ordered=/^\s*\d+\./.test(line), tag=ordered?'ol':'ul', items=[];
      while (i<lines.length && /^\s*([-*]|\d+\.) /.test(lines[i])) items.push('<li>'+inline(lines[i++].replace(/^\s*([-*]|\d+\.) /,''))+'</li>');
      i--;
      output.push('<'+tag+'>'+items.join('')+'</'+tag+'>');
    } else if (line.trim()) output.push('<p>'+inline(line)+'</p>');
  }
  return output.join('');
}

function aiPage(ctx) {
  const turns=ctx.ai.turns;
  const conversations=(ctx.ai.conversations||[]).map(item=>
    `<button class="ai-thread ${item.thread===ctx.ai.thread?'selected':''}" data-act="ai-thread" data-id="${h(item.thread)}">${icon('ai',17)}<span>${h(item.question||'新对话')}</span></button>`).join('');
  return pageHeading('AI 对话','',action('新对话','ai-new','plus','primary'))+
    `<div class="ai-grid"><section class="content-card ai-sidebar"><div class="section-head"><h2>历史对话</h2></div>
    ${conversations||'<p>暂无历史对话</p>'}</section><section class="content-card ai-content">
    <div class="ai-turns" id="ai-turns">${turns.length?turns.map(turn=>`<div class="ai-turn"><div class="ai-user"><strong>你</strong><p>${h(turn.question)}</p>
    ${turn.has_image?`<button class="link" data-act="ai-image" data-id="${Number(turn.id)}">查看图片</button>`:''}</div>
    <div class="ai-answer"><strong>${icon('ai',18)}AI</strong>
    <div class="markdown">${turn.state==='done'?markdown(turn.answer):`<p>${h(turn.state==='failed'?turn.error||'暂时无法回答':'正在分析…')}</p>`}</div></div></div>`).join(''):
      empty('ai',ctx.ai.loading?'正在打开对话':'问问 AI','查询和汇总已同步的任务、账单与便签。')}</div>
    <form class="composer" id="ai-send"><textarea name="text" rows="3" maxlength="4000" placeholder="例如：这个月的支出按支付方式怎么分布？" aria-label="输入问题">${h(ctx.ai.draft)}</textarea>
    <div class="composer-tools"><label class="small-action">${icon('image',17)}添加图片<input type="file" id="ai-file" accept="image/png,image/jpeg,image/webp,image/gif"></label>
      ${ctx.ai.file?`<span class="attached">${h(ctx.ai.file.name)}</span>${tile('移除图片','ai-remove','close')}`:''}
      ${ctx.canDictate?action('语音输入','dictate-ai','mic','ghost'):''}<button type="submit" class="button primary push-right" ${ctx.ai.sending?'disabled':''}>${icon('send',16)}${ctx.ai.sending?'发送中':'发送'}</button></div></form>
    </section></div>`;
}

function trashPage(ctx) {
  const rows=[...list(ctx.state,ctx.team,T.task,true),...list(ctx.state,ctx.team,T.bill,true)]
    .filter(row=>row.data.name && row.data.name.toLocaleLowerCase().includes(ctx.query.toLocaleLowerCase())).sort((a,b)=>b.edited-a.edited);
  return pageHeading('回收站','')+`<section class="content-card trash-card">${rows.length?rows.map(row=>
    `<div><span>${icon(row.table===T.task?'tasks':'bills',19)}${h(row.data.name)}</span><button class="button secondary" data-act="restore" data-id="${h(row.uid)}" data-table="${row.table}">恢复</button></div>`).join(''):
    empty('trash','回收站为空','已删除的任务和账单会显示在这里。')}</section>`;
}

export function shell(ctx) {
  const renderPage=ctx.page==='tasks'||ctx.page==='timeline'?tasksPage:ctx.page==='bills'?billsPage:
    ctx.page==='notes'?notesPage:ctx.page==='ai'?aiPage:trashPage;
  return `<div class="shell">${sidebar(ctx)}<div class="workspace">${header(ctx)}<main id="page" class="page page-${ctx.page}">${renderPage(ctx)}</main></div></div>`;
}

export function signin({ qr, code, message, loading }) {
  return `<div class="signin"><section class="signin-brand">
    <div class="signin-heading"><span class="brand-mark">${icon('logo',32)}</span><h1>高效 Todo</h1><p>任务、时间安排和记录，集中在一个工作台。</p></div>
    <div class="signin-modules">${['tasks','timeline','bills','notes','ai'].map(page=>`<span>${icon(page,18)}${pages[page]}</span>`).join('')}</div>
  </section><section class="signin-content"><div class="login-card"><h2>手机扫码登录</h2>
    <p>手机 App 中打开「账户与服务端」，选择「扫码登录桌面端」。</p>
    <div class="qr-box">${qr?'<canvas id="qr" role="img" aria-label="手机登录二维码"></canvas>':`<div class="qr-placeholder">${icon('grid',36)}<span>${loading?'正在获取二维码':'等待扫码'}</span></div>`}</div>
    ${code?`<div class="confirm-code">核对码 <strong>${h(code)}</strong></div>`:''}
    <div class="login-status" role="status">${h(message||'请在手机上确认相同的核对码。')}</div>
    ${action('刷新二维码','qr-refresh','sync','secondary')}</div></section></div>`;
}
