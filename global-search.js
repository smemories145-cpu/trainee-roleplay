/* STARLIGHT RP global search — read-only */
(()=>{
'use strict';
const css='.sl-find{font:inherit;color:var(--txt);background:var(--card2);border:1px solid var(--line);border-radius:9px;padding:7px 12px;cursor:pointer}.sl-find:hover{border-color:var(--pri)}.sl-find-overlay{position:fixed;inset:0;background:#05030bd9;backdrop-filter:blur(6px);z-index:160;display:flex;align-items:flex-start;justify-content:center;padding:8vh 12px 20px}.sl-find-panel{background:var(--card);border:1px solid var(--line);box-shadow:0 25px 80px #0009;border-radius:17px;width:min(660px,100%);max-height:80vh;display:flex;flex-direction:column;overflow:hidden}.sl-find-head{padding:15px;display:flex;gap:10px;align-items:center;border-bottom:1px solid var(--line)}.sl-find-head input{flex:1;min-width:0;margin:0;background:transparent;border:0;outline:0}.sl-find-head button{font:inherit;color:var(--txt);background:var(--card2);border:1px solid var(--line);border-radius:7px;cursor:pointer;padding:6px 12px}.sl-find-items{overflow-y:auto;padding:12px}.sl-find-cat{font-size:12px;color:var(--mut);margin:12px 8px 4px}.sl-find-item{display:flex;width:100%;gap:12px;align-items:center;text-align:left;border:1px solid transparent;border-radius:10px;background:transparent;color:var(--txt);font:inherit;cursor:pointer;padding:10px}.sl-find-item:hover,.sl-find-item:focus-visible,.sl-find-item.active{background:var(--card2);border-color:var(--line);outline:none}.sl-find-item strong{display:block;font-size:14px}.sl-find-item small{color:var(--mut);display:block;font-size:12px}.sl-find-icon{font-size:20px;width:32px;text-align:center;color:var(--pri)}.sl-find-empty{padding:24px;text-align:center;color:var(--mut)}.sl-find-foot{font-size:12px;color:var(--mut);padding:9px 17px;border-top:1px solid var(--line)}@media(max-width:600px){.sl-find-overlay{padding-top:18px}.sl-find-panel{max-height:88vh}}';
const style=document.createElement('style');style.textContent=css;document.head.appendChild(style);
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const lower=v=>String(v??'').normalize('NFKC').toLocaleLowerCase();
const read=k=>{try{return DB.get(k)||[]}catch{return []}};
let popup=null,results=[],selected=0,previous=null;
function items(){
 const fs=read('forums'),as=read('agencies'),fn=new Map(fs.map(x=>[x.id,x.name])),an=new Map(as.map(x=>[x.id,x.name])),arr=[];
 const add=(cat,icon,title,detail,path)=>{if(path&&title)arr.push({cat,icon,title:String(title),detail:String(detail||''),path})};
 fs.forEach(x=>add('ฟอรั่ม','▤',x.name,x.desc,'forum/'+x.id));
 read('threads').forEach(x=>add('กระทู้','✎',x.title,fn.get(x.forumId),'thread/'+x.id));
 read('characters').filter(x=>x.status==='approved').forEach(x=>add('ตัวละคร','✧',x.stageName||x.name,[x.name!==x.stageName?x.name:'',an.get(x.agencyId)].filter(Boolean).join(' · '),'char/'+x.id));
 as.forEach(x=>add('ค่ายเพลง','♫',x.name,x.desc,'agency/'+x.id));
 read('groups').forEach(x=>add('ศิลปิน/วง','☆',x.name,x.desc,'group/'+x.id));
 return arr;
}
function close(){if(!popup)return;popup.remove();popup=null;document.removeEventListener('keydown',keys,true);if(previous?.isConnected)previous.focus()}
function jump(i){const x=results[i];if(!x)return;close();if(typeof go==='function')go(x.path);else location.hash=x.path}
function display(){
 if(!popup)return;
 const words=lower(popup.querySelector('input').value).trim().split(/\s+/).filter(Boolean);
 results=items().filter(x=>words.every(w=>lower(x.cat+' '+x.title+' '+x.detail).includes(w))).slice(0,80);
 selected=Math.min(selected,Math.max(0,results.length-1));
 const box=popup.querySelector('.sl-find-items');
 if(!results.length){box.innerHTML='<div class="sl-find-empty">ไม่พบผลลัพธ์ ลองใช้คำค้นอื่นดูนะ</div>';return}
 let out='',cat='';
 results.forEach((x,i)=>{if(x.cat!==cat){cat=x.cat;out+='<div class="sl-find-cat">'+esc(cat)+'</div>'}out+='<button type="button" class="sl-find-item'+(i===selected?' active':'')+'" data-index="'+i+'"><span class="sl-find-icon">'+x.icon+'</span><span><strong>'+esc(x.title)+'</strong><small>'+esc(x.detail)+'</small></span></button>'});
 box.innerHTML=out;
}
function keys(e){
 if(e.key==='Escape'){e.preventDefault();close();return}
 if(!['ArrowDown','ArrowUp','Enter'].includes(e.key))return;
 e.preventDefault();
 if(e.key==='Enter'){jump(selected);return}
 if(!results.length)return;
 selected=(selected+(e.key==='ArrowDown'?1:-1)+results.length)%results.length;
 popup.querySelectorAll('.sl-find-item').forEach(x=>x.classList.toggle('active',Number(x.dataset.index)===selected));
 popup.querySelector('.sl-find-item.active')?.scrollIntoView({block:'nearest'});
}
function open(){
 if(popup){popup.querySelector('input').focus();return}
 previous=document.activeElement;selected=0;
 popup=document.createElement('div');popup.className='sl-find-overlay';
 popup.innerHTML='<section class="sl-find-panel" role="dialog" aria-modal="true" aria-label="ค้นหาทั่วเว็บไซต์"><div class="sl-find-head"><span aria-hidden="true">⌕</span><input type="search" placeholder="ค้นหากระทู้ ตัวละคร ฟอรั่ม ค่ายเพลง..." aria-label="คำค้นหา"><button type="button" data-close>ปิด ×</button></div><div class="sl-find-items"></div><div class="sl-find-foot">↑ ↓ เลือก · Enter เปิด · Esc ปิด · Ctrl/⌘ K ค้นหา</div></section>';
 document.body.appendChild(popup);
 popup.addEventListener('click',e=>{if(e.target===popup||e.target.closest('[data-close]'))close();else if(e.target.closest('[data-index]'))jump(Number(e.target.closest('[data-index]').dataset.index))});
 popup.querySelector('input').addEventListener('input',()=>{selected=0;display()});
 document.addEventListener('keydown',keys,true);display();popup.querySelector('input').focus();
}
function attach(){
 const links=document.querySelector('#nav .links');if(!links||links.querySelector('.sl-find'))return;
 const b=document.createElement('button');b.type='button';b.className='sl-find';b.textContent='⌕ ค้นหา';b.setAttribute('aria-label','ค้นหาทั่วเว็บไซต์ Ctrl K');b.addEventListener('click',open);links.prepend(b);
}
document.addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='k'){e.preventDefault();open()}},true);
function init(){attach();const nav=document.getElementById('nav');if(nav)new MutationObserver(attach).observe(nav,{childList:true})}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});else init();
})();