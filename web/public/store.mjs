const ready = new Promise((resolve, reject) => {
  const request = indexedDB.open('gxtodo-web', 1);
  request.onupgradeneeded = () => {
    request.result.createObjectStore('workspaces');
    request.result.createObjectStore('files');
  };
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});

const blank = () => ({ rows: {}, cursors: {}, spaces: [] });

export async function read(scope) {
  const db = await ready;
  return new Promise((resolve, reject) => {
    const request = db.transaction('workspaces').objectStore('workspaces').get(scope);
    request.onsuccess = () => resolve(request.result || blank());
    request.onerror = () => reject(request.error);
  });
}

// Read and apply changes in one transaction. The callback does no network I/O.
export async function change(scope, edit, files = []) {
  const db = await ready;
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(['workspaces', 'files'], 'readwrite');
    const workspace = transaction.objectStore('workspaces');
    const storedFiles = transaction.objectStore('files');
    const request = workspace.get(scope);
    let result;
    let error;
    request.onsuccess = () => {
      try {
        result = request.result || blank();
        edit(result);
        workspace.put(result, scope);
        for (const [key, file] of files) storedFiles.put(file, [scope, key]);
      } catch (caught) {
        error = caught;
        transaction.abort();
      }
    };
    transaction.oncomplete = () => resolve(result);
    transaction.onabort = () => reject(error || transaction.error);
  });
}

export async function getFile(scope, id) {
  if (!id) return undefined;
  const db = await ready;
  return new Promise((resolve, reject) => {
    const request = db.transaction('files').objectStore('files').get([scope, id]);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
