"use strict";

const $ = (id) => document.getElementById(id);
const node = (tag, text) => Object.assign(document.createElement(tag), { textContent: text });
const modes = { polling: "权威本机控制", observer: "只读观察", play: "远端玩家 · 只读" };
const connectionNames = { connecting: "连接中", joined: "已入席", retrying: "等待重连" };
let lastStatus, selectedRun, selectedFile, historyRevision = 0, recordRevision = 0;
let readOnly = true, refreshing = false;

function readStatus(status) {
  const lines = status.split(/\r?\n/);
  const field = (name) => lines.find((line) => line.startsWith(name + "="))?.slice(name.length + 1);
  const mode = field("control");
  const body = lines.find((line) => line.startsWith("bodies ")) || "";
  const rosterLine = lines.find((line) => line.startsWith("OK role=")) || "";
  const roster = rosterLine.split(" roster=")[1] || "";
  const players = [...roster.matchAll(/(?:^| )(\d+):([^\r\n]+?):(up|down)(?= |$)/g)]
    .map(([, seat, name, connection]) => ({ seat, name, connection }));
  const host = body.match(/\bhero=(\d+)(?::x=(-?\d+):y=(-?\d+))?/);
  const map = body.match(/(?:^| )map=(\S+)/)?.[1];
  const hostStatus = body.match(/\bhostInput=(.*?)(?= appliedSeq=| enter=| play=| map=| \d+:|$)/)?.[1];
  const guests = players.map((player) => {
    const prefix = " " + player.seat + ":" + player.name + ":";
    const start = body.indexOf(prefix);
    return { player, start, end: start + prefix.length };
  }).filter((guest) => guest.start >= 0).sort((a, b) => a.start - b.start);
  const guestRows = new Map(guests.map(({ player, end }, index) =>
    [player, body.slice(end, guests[index + 1]?.start)]));
  const claims = lines.filter((line) => line.startsWith("claim reward=")).map((line) =>
    Object.fromEntries([...line.matchAll(/(?:^| )(\w+)=([^ ]*)/g)].map(([, key, value]) => [key, value])));
  const hostInfo = body.slice(0, guests[0]?.start);
  for (const player of players) {
    const guest = guestRows.get(player);
    const isHost = guest === undefined && player.seat === "1" && !rosterLine.startsWith("OK role=serve ");
    const actor = guest?.match(/(?:^| )id=(\d+)(?::x=(-?\d+):y=(-?\d+))?/);
    const info = guest ?? (isHost ? hostInfo : "");
    const id = actor || (isHost ? host : undefined);
    player.actor = id?.[1];
    player.position = id?.[2] === undefined ? undefined : id[2] + ", " + id[3];
    player.applied = info.match(/\bappliedSeq=(\d+)/)?.[1];
    player.offline = info.match(/\bofflineBatch=(\d+)/)?.[1];
    player.load = info.match(/\bload=(\d+)/)?.[1];
    player.publication = info.match(/\bpublication=(\d+)/)?.[1];
    player.state = guest?.split(" id=")[0] ?? (isHost ? hostStatus : undefined);
  }
  return { mode, room: field("room") || map, tick: field("tick"), players, claims,
    connection: field("connection"), seat: field("seat"), sent: field("sentSeq"), reason: field("reason"),
    actors: lines.filter((line) => /^(hero|enemy) id=/.test(line)),
    receipts: lines.filter((line) => /^(OK |ERR |claim reward=.* state=consumed )/.test(line) &&
      !/^OK (role=|none$|\d+:)/.test(line)).map((line) => line.replace(
      /^claim reward=(\d+) kind=(\S+) seat=(\d+) state=consumed choice=(.+)$/,
      "席 $3 已领取 $4（$2，奖励 $1）")).concat(
      [...body.matchAll(/ (enter|play)=(.*?)(?= enter=| play=| map=| \d+:|$)/g)].map(([, key, result]) => key + "=" + result)),
    queued: lines.some((line) => line.startsWith("queue=")) };
}

function button(label, handler) {
  const el = node("button", label);
  el.type = "button";
  el.addEventListener("click", handler);
  return el;
}

function renderPlayers(status) {
  const cards = status.players.map((player) => {
    const card = node("article", "");
    card.className = "player";
    const connection = node("span", player.connection === "up" ? "在线" : "离线 · 保留席位");
    connection.className = player.connection;
    card.append(node("h3", "席 " + player.seat + " · " + player.name), connection);
    const details = node("dl", "");
    for (const [label, value] of [
      ["角色 ID", player.actor], ["位置 X, Y", player.position], ["最近应用序号", player.applied],
      ["离线中立批次", player.offline], ["房间装载", player.load], ["发布代际", player.publication],
      ["原版输入", player.state]
    ]) {
      if (value !== undefined) details.append(node("dt", label), node("dd", value));
    }
    card.append(details);
    if (!readOnly) {
      if (player.connection === "up") {
        card.append(button("选作输入席", () => { $("seat").value = player.seat; $("axisX").focus(); }),
          button("断线", () => send("player/remove", { who: player.seat })));
      } else {
        card.append(button("按原名重连", () => send("player/add", { name: player.name })));
      }
    }
    return card;
  });
  if (cards.length === 0) {
    for (const actor of status.actors) cards.push(node("p", actor));
  }
  $("players").replaceChildren(...(cards.length ? cards : [node("p", "当前状态未提供角色或名册。")]));
}

function renderBoons(claims) {
  const panel = $("boons");
  const key = JSON.stringify([readOnly, claims]);
  if (panel.dataset.view === key) return;
  panel.dataset.view = key;
  panel.hidden = claims.length === 0;
  $("boonClaims").replaceChildren(...claims.map((claim) => {
    const card = node("article", "");
    card.className = "player";
    card.append(node("h3", "席 " + claim.seat + " · 奖励 " + claim.reward));
    if (claim.state === "consumed") {
      card.append(node("p", "已领取 · " + claim.choice));
    } else {
      const options = (claim.options || "").split(",").filter(Boolean);
      card.append(node("p", "候选 · " + (options.join("、") || "暂无")));
      if (claim.selected) card.append(node("p", "待确认 · " + claim.selected));
      if (!readOnly && claim.opportunity && options.includes(claim.grantOption)) {
        card.append(button("领取 " + claim.grantOption, () => send("boon", {
          seat: claim.seat, opportunity: claim.opportunity, option: claim.grantOption
        })));
      }
    }
    return card;
  }));
}

function rememberStatus(text, updatedAt) {
  const details = node("details", "");
  details.append(node("summary", updatedAt ? new Date(updatedAt).toLocaleTimeString() : "本页读取"),
    node("pre", text));
  $("recent").prepend(details);
  if ($("recent").children.length > 8) $("recent").lastElementChild.remove();
}

async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try {
    const response = await fetch("/api/live");
    if (!response.ok) throw new Error("HTTP " + response.status);
    const { status, updatedAt } = await response.json();
    const view = readStatus(status);
    const changed = lastStatus !== status || readOnly !== (view.mode !== "polling");
    readOnly = view.mode !== "polling";
    for (const id of ["join", "input", "gameCommands"]) $(id).hidden = readOnly;
    $("mode").textContent = (modes[view.mode] || "等待游戏状态") + (view.queued ? " · 队列待处理" : "");
    $("room").textContent = (view.room || "—") + (view.tick ? " · tick " + view.tick : "");
    $("updated").textContent = updatedAt ? new Date(updatedAt).toLocaleString() : "—";
    $("connection").hidden = view.mode !== "play";
    $("connection").textContent = [
      connectionNames[view.connection] || view.connection || "等待连接状态",
      view.seat && "本机席位 " + view.seat,
      view.sent && "本机已发送序号 " + view.sent,
      view.reason
    ].filter(Boolean).join(" · ");
    $("receipts").textContent = view.receipts.join("\n") || "—";
    $("raw").textContent = status;
    if (changed) renderPlayers(view);
    renderBoons(view.claims);
    if (status !== lastStatus) rememberStatus(status, updatedAt);
    lastStatus = status;
    $("liveError").hidden = true;
  } catch (error) {
    readOnly = true;
    lastStatus = undefined;
    for (const id of ["join", "input", "gameCommands"]) $(id).hidden = true;
    $("players").replaceChildren(node("p", "状态读取暂不可用。上次读数见下方记录。"));
    renderBoons([]);
    $("liveError").textContent = "读取失败 · " + error.message;
    $("liveError").hidden = false;
  } finally {
    refreshing = false;
  }
}

async function send(path, query) {
  if (readOnly) return;
  const list = $("commands");
  if (list.firstElementChild?.textContent === "本页尚未提交命令") list.firstElementChild.remove();
  const entry = node("li", "正在提交…");
  list.prepend(entry);
  if (list.children.length > 12) list.lastElementChild.remove();
  try {
    const response = await fetch("/api/" + path + "?" + new URLSearchParams(query), { method: "POST" });
    const body = (await response.text()).trim();
    entry.textContent = new Date().toLocaleTimeString() + " · " +
      (response.ok ? body.replace(/^queued /, "已排队 · ") : "未排队 · " + body);
  } catch (error) {
    entry.textContent = "提交结果未知 · " + error.message;
  }
  refresh();
}

async function viewRecord(run, file) {
  const revision = ++recordRevision;
  selectedRun = run;
  selectedFile = file;
  $("recordName").textContent = run.id;
  $("recordFiles").replaceChildren(...run.files.map((name) => {
    const el = button(name, () => viewRecord(run, name));
    el.setAttribute("aria-pressed", String(name === file));
    return el;
  }));
  $("record").textContent = "正在读取 " + file + "…";
  try {
    const response = await fetch("/api/history/file?" + new URLSearchParams({ run: run.id, file }));
    if (!response.ok) throw new Error("HTTP " + response.status);
    const text = await response.text();
    if (revision === recordRevision) $("record").textContent = text || "文件为空。";
  } catch (error) {
    if (revision === recordRevision) $("record").textContent = "归档读取失败 · " + error.message;
  }
}

async function listHistory() {
  const revision = ++historyRevision;
  try {
    const response = await fetch("/api/history");
    if (!response.ok) throw new Error("HTTP " + response.status);
    const runs = await response.json();
    if (revision !== historyRevision) return;
    $("runs").replaceChildren(...(runs.length ? runs.map((run) =>
      button(run.id, () => viewRecord(run, run.files[0]))) : [node("p", "控制目录中暂无运行归档。")]));
    const current = runs.find((run) => run.id === selectedRun?.id);
    if (current) viewRecord(current, current.files.includes(selectedFile) ? selectedFile : current.files[0]);
    else if (selectedRun) {
      ++recordRevision;
      selectedRun = selectedFile = undefined;
      $("recordName").textContent = "选择一条运行记录";
      $("recordFiles").replaceChildren();
      $("record").textContent = "原选中的归档已不在列表中。";
    }
  } catch (error) {
    if (revision === historyRevision) $("runs").replaceChildren(node("p", "归档列表读取失败 · " + error.message));
  }
}

function changeView(history) {
  $("history").hidden = !history;
  $("live").hidden = history;
  $("showHistory").setAttribute("aria-pressed", String(history));
  $("showLive").setAttribute("aria-pressed", String(!history));
  if (history) listHistory();
  else refresh();
}

$("showLive").addEventListener("click", () => changeView(false));
$("showHistory").addEventListener("click", () => changeView(true));
$("reloadHistory").addEventListener("click", listHistory);
$("join").addEventListener("submit", (event) => {
  event.preventDefault();
  send("player/add", { name: $("name").value });
});
$("input").addEventListener("submit", (event) => {
  event.preventDefault();
  const actions = Array.from($("input").querySelectorAll("input:checked"), (el) => el.value);
  send("input", { seat: $("seat").value, x: $("axisX").value, y: $("axisY").value, actions: actions.join(" ") });
});
$("zero").addEventListener("click", () => {
  if ($("seat").reportValidity()) send("input", { seat: $("seat").value, x: "0", y: "0" });
});
$("gameCommands").addEventListener("submit", (event) => {
  event.preventDefault();
  send("enter", { map: $("map").value });
});
$("play").addEventListener("click", () => send("play"));
refresh();
setInterval(() => { if ($("history").hidden) refresh(); }, 1000);
