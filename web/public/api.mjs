import { T, applyPage, fileParent, get, id, pendingRows, put } from './domain.mjs';
import { change, getFile, read } from './store.mjs';

export async function request(path, values, signal) {
  const form = values instanceof FormData;
  const response = await fetch('/api/' + path, values === undefined ? { signal } : {
    method:'POST', signal, headers: form ? undefined : { 'Content-Type':'application/json' },
    body:form?values:JSON.stringify(values),
  });
  if (response.ok && !response.headers.get('content-type')?.includes('application/json')) {
    return { blob:await response.blob(), type:response.headers.get('x-file-type') };
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(data.message || '请求失败，请重试');
    error.status = response.status;
    error.code = data.code;
    throw error;
  }
  return data;
}

export async function digest(data) {
  const source = typeof data === 'string' ? new TextEncoder().encode(data) : await data.arrayBuffer();
  const checksum = await crypto.subtle.digest('SHA-256',source);
  return [...new Uint8Array(checksum)].map(byte=>byte.toString(16).padStart(2,'0')).join('');
}

export async function stageFiles(files, table) {
  const staged = [];
  for (const file of files) {
    if (file.size > 100 * 1024 * 1024 || !file.size) throw new Error('附件必须非空，单文件上限 100 MB');
    const kind = file.type.startsWith('image/')?'image':file.type.startsWith('audio/')?'audio':'file';
    if (table===T.entry && kind==='file') throw new Error('便签支持图片和音频附件');
    const uid = id(table), key = 'media-' + crypto.randomUUID();
    staged.push({ uid,key,file,data:{ kind, client_media_id:key, media_name:file.name, size:file.size, sha256:await digest(file) } });
  }
  return staged;
}

export function addFiles(state, staged, account, parent, table) {
  for (const { uid,data } of staged) put(state,account.id,parent.team,table,uid,
    { ...data, note_id:parent.uid, parent_table:parent.table, entry_at:Date.now(), detached:0, media_id:'' });
}

export class Workspace {
  constructor(account, update) {
    this.account=account;
    this.scope=account.server + '/' + account.id;
    this.update=update;
    this.state=null;
    this.busy=false;
    this.active=true;
    this.channel=new BroadcastChannel('gxtodo-workspaces');
    this.channel.onmessage = async event => {
      if (event.data===this.scope && this.active) this.install(await read(this.scope));
    };
  }

  install(state) {
    if (!this.active) return;
    this.state=state;
    this.update();
  }

  async initialize() {
    this.install(await change(this.scope, state => {
      if (!state.spaces.length) state.spaces=this.account.spaces;
    }));
  }

  async edit(action, staged=[]) {
    if (!this.active) throw new Error('请重新登录后再操作');
    this.install(await change(this.scope,action,staged.map(part=>[part.key,part.file])));
    this.channel.postMessage(this.scope);
  }

  async sync() {
    if (this.busy || !this.active) return;
    this.busy=true;
    try {
      if (navigator.locks) await navigator.locks.request('gxtodo-sync:' + this.scope, { ifAvailable:true },
        async lock=>lock && this.active && this.syncLocked());
      else await this.syncLocked();
    } finally {
      this.busy=false;
    }
  }

  async syncLocked() {
    const account=this.account;
    const teams=(await request('teams',{})).data;
    if (!Array.isArray(teams)) throw new Error('服务端返回的空间列表无效');
    if (!this.active) return;
    await this.edit(state => {
      const personal=state.spaces.find(space=>Number(space.id)===account.personal) ||
        { id:account.personal, type:1, name:'个人空间' };
      state.spaces=[personal,...teams.filter(space=>Number(space.type)!==1 && Number(space.id)>0)];
    });
    const failed = new Set();
    for (let page=0;page<250 && this.active;page++) {
      const snapshot=await read(this.scope);
      const active=new Set(snapshot.spaces.map(space=>Number(space.id)));
      const uploads=Object.values(snapshot.rows).filter(row=>active.has(row.team) && row.pending && !row.removed &&
        fileParent[row.table] && row.data.kind!=='text' && !row.data.media_id &&
        !failed.has(row.uid) && Number(get(snapshot,row.team,fileParent[row.table],row.data.note_id)?.revision)>0);
      for (const row of uploads) {
        try {
          const key=row.data.client_media_id, file=await getFile(this.scope,key);
          if (!file) throw new Error('本地附件已移除');
          const form=new FormData();
          for (const [name,value] of Object.entries({ team_id:row.team, note_id:row.data.note_id, kind:row.data.kind,
            parent_table:fileParent[row.table], client_id:key, sha256:row.data.sha256 })) form.set(name,value);
          form.set('file',file,row.data.media_name);
          const { data }=await request('files/upload',form);
          if (!data?.id) throw new Error('附件上传响应无效');
          if (!this.active) return;
          await this.edit(current => {
            const latest=get(current,row.team,row.table,row.uid);
            if (!latest || latest.removed || latest.data.client_media_id!==key) return;
            put(current,account.id,row.team,row.table,row.uid,
              { media_id:data.id, content_type:data.content_type, size:data.size, sha256:data.sha256 });
          });
        } catch (error) {
          if (error.status===401) throw error;
          failed.add(row.uid);
        }
      }
      const current=await read(this.scope);
      const batch=pendingRows(current);
      const reply=await request('sync',{
        entropy:Object.fromEntries([...active].map(team=>['t'+team,current.cursors['t'+team]||0])),
        record_versions:1,bill_currency:1,_data:batch.map(change=>change.payload),
      });
      if (!this.active) return;
      await this.edit(state=>applyPage(state,batch.map(change=>change.row),reply));
      if (!reply.down_extra.some(marker=>Number(marker.remain)>0) && !pendingRows(this.state).length) {
        const waiting=Object.values(this.state.rows).some(row=>row.pending && !row.removed && active.has(row.team) &&
          fileParent[row.table] && row.data.kind!=='text' && !row.data.media_id && !failed.has(row.uid));
        if (waiting && batch.length) continue;
        if (failed.size || waiting) throw new Error('文字已同步，附件将在联网时重试');
        return;
      }
    }
    if (this.active) throw new Error('记录较多，剩余数据将在下一轮继续同步');
  }

  async file(row) {
    const key=row.data.client_media_id || ('remote-' + row.data.media_id);
    const local=await getFile(this.scope,key);
    if (local) return local;
    if (!row.data.media_id) throw new Error('附件还在等待同步');
    const { blob,type }=await request('files/read',{ id:row.data.media_id });
    if (!(blob instanceof Blob)) throw new Error('未能读取附件');
    if (Number(row.data.size)>0 && blob.size!==Number(row.data.size)) throw new Error('附件大小校验失败');
    if (row.data.sha256 && await digest(blob)!==row.data.sha256) throw new Error('附件完整性校验失败');
    const file=blob.slice(0,blob.size,type || row.data.content_type);
    if (this.active) await change(this.scope,()=>{},[[key,file]]);
    return file;
  }

  stop() {
    this.active=false;
    this.channel.close();
  }
}
