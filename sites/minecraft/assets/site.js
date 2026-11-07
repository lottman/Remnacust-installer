'use strict';
const $ = s => document.querySelector(s);
const $$ = s => Array.from(document.querySelectorAll(s));
const storageKey = document.body.dataset.site + ':';
const memory = new Map();
function read(key, fallback) { try { const raw = localStorage.getItem(storageKey + key); return raw === null ? (memory.has(key) ? memory.get(key) : fallback) : JSON.parse(raw); } catch { return memory.has(key) ? memory.get(key) : fallback; } }
function store(key, value) { memory.set(key, value); try { localStorage.setItem(storageKey + key, JSON.stringify(value)); return true; } catch { return false; } }
function say(text) { const el = $('#status'); if (el) el.textContent = text; }
function show(text) { const el = $('#result'); if (el) el.textContent = text; }
function num(id) { return Number($('#' + id).value); }
function download(name, text, type = 'text/plain;charset=utf-8') { const url = URL.createObjectURL(new Blob([text], {type})); const a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
const form = $('#tool');
function onTool(fn) { if (form) form.addEventListener('submit', event => { event.preventDefault(); if (form.reportValidity()) fn(); }); }
$$('[data-save]').forEach(button => { let saved = read('saved', []); if (!Array.isArray(saved)) saved = []; const refresh = () => { const yes = saved.includes(button.dataset.save); button.setAttribute('aria-pressed', String(yes)); button.textContent = yes ? 'Saved' : 'Save'; }; refresh(); button.addEventListener('click', () => { saved = read('saved', []); if (!Array.isArray(saved)) saved = []; saved = saved.includes(button.dataset.save) ? saved.filter(v => v !== button.dataset.save) : [...saved, button.dataset.save]; const persisted = store('saved', saved); refresh(); say(persisted ? 'Saved choices updated in this browser.' : 'Browser storage is unavailable; this choice lasts until you leave.'); }); });
$$('[data-checklist]').forEach(box => { let checks = read(box.dataset.checklist, []); if (!Array.isArray(checks)) checks = []; box.querySelectorAll('input[type=checkbox]').forEach(input => { input.checked = checks.includes(input.value); input.addEventListener('change', () => { const selected = Array.from(box.querySelectorAll('input:checked')).map(v => v.value); const persisted = store(box.dataset.checklist, selected); say(selected.length + ' items checked' + (persisted ? '; saved in this browser.' : '; browser storage is unavailable.')); }); }); });
const search = $('#search');
const category = $('#category');
function filterItems() { const query = (search?.value || '').trim().toLowerCase(); const chosen = category?.value || 'all'; let count = 0; $$('[data-item]').forEach(item => { const match = item.textContent.toLowerCase().includes(query) && (chosen === 'all' || item.dataset.category === chosen); item.hidden = !match; if (match) count++; }); const empty = $('#empty'); if (empty) empty.hidden = count !== 0; const result = $('#count'); if (result) result.textContent = count + ' matches'; }
search?.addEventListener('input', filterItems); category?.addEventListener('change', filterItems);
if (search || category) filterItems();
function settings(){ return '# Review before use; generated locally\nonline-mode=true\nwhite-list=true\nserver-port=25565\nmax-players='+Math.round(num('players'))+'\nview-distance=8\nsimulation-distance=6\nmotd='+$('#motd').value.slice(0,64).replace(/[\\:=#!\r\n]/g,' ')+'\n'; } onTool(()=>{const base={vanilla:2,plugins:3,mods:5}[$('#world').value];show('Suggested initial RAM: '+Math.ceil(base+num('players')*.18)+' GiB.\nBackup allowance: '+Math.ceil(num('worldsize')*num('copies')*1.2)+' GiB, separate from the live world.\nReview CPU tick time before expanding.');});$('#properties')?.addEventListener('click',()=>{if(form.reportValidity()){download('server.properties',settings());say('Settings downloaded. Review them before use.');}});
