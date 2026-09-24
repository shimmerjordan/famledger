// 入口脚本以 root 修好数据目录属主后，用它降权，再在同一个进程里加载服务端。
// 不用 gosu/su-exec：那要多装一个包，而 Node 自带 setgid/setuid 就够了。
// 在同一个进程里加载（不再 fork 一层），PID 1 仍然是 node，docker stop 的 SIGTERM 直达。
//
//   DROP_UID=1000 DROP_GID=1000 node drop-privs.mjs /app/server/src/server.js
const uid = Number(process.env.DROP_UID);
const gid = Number(process.env.DROP_GID);
const entry = process.argv[2];

if (!entry) {
  console.error('[drop-privs] 缺少入口参数');
  process.exit(2);
}

if (process.getuid?.() === 0 && Number.isInteger(uid) && uid > 0) {
  // 顺序要紧：先丢附加组和 gid，再丢 uid（反过来就没权限改组了）。
  // 降权失败宁可退出，也不以 root 跑服务。
  try {
    process.setgroups?.([gid]);
    process.setgid(gid);
    process.setuid(uid);
  } catch (err) {
    console.error(`[drop-privs] 降权到 ${uid}:${gid} 失败：${err.message}`);
    process.exit(1);
  }
}

process.argv.splice(1, 2, entry);
const { pathToFileURL } = await import('node:url');
await import(pathToFileURL(entry).href);
