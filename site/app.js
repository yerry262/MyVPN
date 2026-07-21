const DEVICES_URL = 'https://raw.githubusercontent.com/yerry262/MyVPN/main/devices.json';
const STATUS_URL = 'https://raw.githubusercontent.com/yerry262/MyVPN/status/status.json';
const REFRESH_MS = 30000;

const rowsEl = document.getElementById('rows');
const updatedEl = document.getElementById('updated');

let deviceNames = null; // fetched once, list of {name} from devices.json

async function fetchJson(url) {
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error(`${url} -> ${res.status}`);
  return res.json();
}

function render(names, statusByName) {
  rowsEl.replaceChildren();
  for (const name of names) {
    const online = statusByName.get(name) === true;

    const bulb = document.createElement('div');
    bulb.className = `bulb ${online ? 'bulb-on' : 'bulb-off'}`;

    const nameEl = document.createElement('div');
    nameEl.className = `name ${online ? '' : 'name-off'}`;
    nameEl.textContent = name;

    const rowLeft = document.createElement('div');
    rowLeft.className = 'row-left';
    rowLeft.append(bulb, nameEl);

    const pill = document.createElement('div');
    pill.className = `pill ${online ? 'pill-on' : 'pill-off'}`;
    pill.textContent = online ? 'online' : 'offline';

    const row = document.createElement('div');
    row.className = 'row';
    row.append(rowLeft, pill);

    rowsEl.appendChild(row);
  }
}

async function refresh() {
  try {
    if (!deviceNames) {
      const devices = await fetchJson(DEVICES_URL);
      deviceNames = devices.devices.map((d) => d.name);
    }
    const status = await fetchJson(STATUS_URL);
    const statusByName = new Map(status.map((s) => [s.name, s.online]));
    render(deviceNames, statusByName);
    updatedEl.textContent = `updated ${new Date().toLocaleTimeString()}`;
    updatedEl.classList.remove('error');
  } catch (err) {
    // keep showing the last successfully rendered snapshot; just flag staleness
    updatedEl.textContent = `couldn't refresh (${err.message}) — showing last known state`;
    updatedEl.classList.add('error');
  }
}

refresh();
setInterval(refresh, REFRESH_MS);
