// Run with PLAYWRIGHT_MODULE pointing at an installed Playwright package.
// Optional CHROME_EXECUTABLE / FIREFOX_EXECUTABLE select existing browsers.
// Exercises the real report and iframe mounting code with deterministic data.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const zlib = require('node:zlib');
const path = require('node:path');
const {chromium, firefox} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(process.env.MONITOR_HTML || path.join(root, 'analytics/ping-monitor.html'));
const worker = fs.readFileSync(path.join(root, 'analytics/ping-monitor-worker.js'));
const handoff = fs.readFileSync(path.join(root, 'boot-initrd-handoff'), 'utf8');
const mount = handoff.split("<<'ZD_PING_PANEL_V4'\n")[1].split('\nZD_PING_PANEL_V4')[0];
const ap = '94:f6:65:0c:60:b0', client = 'ba:b6:35:f8:9c:a4';
const now = Date.UTC(2026,8,9,12)/1000;
const first = Math.floor((now-5400)/900)*900+30;
const times = Array.from({length:5}, (_, i) => first+i*900);
const snrs = [0, 25, 40, 65, 100];
const dayStart = Math.floor(first/86400)*86400;
const timestampOffset=640, macOffset=660, sampleOffset=672, snrOffset=682,
      stateOffset=692, apMacOffset=704, air24Offset=712, air5Offset=717, meshOffset=722;
const binary=Buffer.alloc(727);
binary.write('ZDPMDAY\0'); binary.writeUInt16LE(2,8); binary.writeUInt16LE(640,10);
for (const [offset,value] of [[12,31],[16,dayStart],[20,dayStart+86400],[24,5],[28,2],[36,timestampOffset],[40,macOffset],[44,sampleOffset],[48,now],[52,snrOffset],[56,stateOffset],[60,1],[64,apMacOffset],[68,air24Offset],[72,air5Offset],[76,meshOffset],[80,binary.length]]) binary.writeUInt32LE(value,offset);
binary.writeUInt16LE(2000,32); binary.writeUInt16LE(254,34);
for(let i=0;i<254;i++) binary.writeUInt16LE(i+1,132+i*2);
times.forEach((t,i)=>binary.writeUInt32LE(t,timestampOffset+i*4));
Buffer.from(ap.replaceAll(':',''),'hex').copy(binary,macOffset);
Buffer.from(client.replaceAll(':',''),'hex').copy(binary,macOffset+6);
Buffer.from(ap.replaceAll(':',''),'hex').copy(binary,apMacOffset);
binary.fill(5,sampleOffset,sampleOffset+10); binary.fill(1,stateOffset,stateOffset+10);
snrs.forEach((snr,i)=>binary[snrOffset+5+i]=snr+1);
binary.fill(2,air5Offset,air5Offset+5); // 1% airtime must remain visible.
const xml = body => `<?xml version="1.0" encoding="utf-8"?><!DOCTYPE ajax-response><ajax-response><response><apstamgr-stat>${body}</apstamgr-stat></response></ajax-response>`;
let fresh = false, indexRequests = 0;
const server=http.createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost'), p=url.pathname;
 const send=(type,body,cache='no-store')=>{res.writeHead(200,{'Content-Type':type,'Cache-Control':cache});res.end(body)};
 const json=body=>send('application/json',JSON.stringify(body));
 if(p==='/admin10/admin_pingtool.jsp') return send('text/html',`<html><body><header>ZoneDirector test shell</header><nav>Network Monitor</nav><div id="main-content"></div><script>${mount}</script></body></html>`);
 if(p.endsWith('/zd1200-network-monitor.html')) return send('text/html',html);
 if(p.endsWith('/zd1200-network-monitor-worker.js')) return send('application/javascript',worker);
 if(p.endsWith('.css')) return send('text/css','.popover{display:none;left:0;max-width:276px}');
 if(p.endsWith('/zd1200-ping-monitor-targets.json')) return json({targets:[{mac:ap,kind:'ap',name:'RuckusAP',ip:'192.168.222.13'},{mac:client,kind:'client',name:'Test device with a very long name that must never collide with its addresses',ip:'192.168.222.102'}]});
 if(p.endsWith('/zd1200-ping-monitor-daily-manifest.json')) return json({generated_at:now,periods:[{start:dayStart,end:dayStart+86400,file:'test.bin.gz',immutable:false}]});
 if(p.endsWith('/test.bin.gz')) return send('application/gzip',zlib.gzipSync(binary));
 if(p.endsWith('/zd1200-ping-monitor-snapshot-manifest.json')) return json({generated_at:now+(fresh?1:0),periods:[{start:dayStart,end:dayStart+86400,file:'zd1200-ping-monitor-snapshot-index/test.json'}]});
 if(p.endsWith('/snapshot-index/test.json')||p.endsWith('/zd1200-ping-monitor-snapshot-index/test.json')) {
  indexRequests++;
  return send('application/json',JSON.stringify({snapshots:fresh?[first-900,...times]:[first-900]}),'public, max-age=86400');
 }
 const snapshot=p.match(/\/(\d+)-(ap|client|mesh)\.xml\.gz$/);
 if(snapshot){
  const [_,t,kind]=snapshot;
  if(fresh&&Number(t)<first){res.writeHead(404);return res.end()}
  const body=kind==='ap'?`<ap mac="${ap}" ap-name="RuckusAP" mesh-depth="0" location="Kitchen"/>`:kind==='mesh'?`<ap mac="${ap}" uplink-mac="00:00:00:00:00:00"/>`:Number(t)>=first?`<client mac="${client}" ap="${ap}" ssid="rzd" radio-type="11ac" channel="124" location="Office"/>`:'';
  return send('application/gzip',zlib.gzipSync(xml(body)));
 }
 if(p.endsWith('/zd1200-ping-monitor-settings.json'))return json({monitoring_enabled:false,interval:60});
 res.writeHead(404);res.end();
});
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const url=`http://127.0.0.1:${server.address().port}/admin10/admin_pingtool.jsp#zd1200_network_monitor`;
 const engines=[['Chrome',chromium,process.env.CHROME_EXECUTABLE]];
 if(process.env.FIREFOX_EXECUTABLE)engines.push(['Firefox',firefox,process.env.FIREFOX_EXECUTABLE]);
 for(const [name,engine,executablePath] of engines){
  fresh=false;indexRequests=0;
  const browser=await engine.launch({headless:true,...(executablePath?{executablePath}:{}),...(name==='Chrome'?{args:['--no-sandbox']}: {})});
  try{
   const context=await browser.newContext({viewport:null});
   await context.addInitScript(value=>{Date.now=()=>value*1000},now);
   const page=await context.newPage();
   await page.goto(url);
   let frame=page.frameLocator('#zd1200-ping-monitor-frame');
   await frame.locator('.row-label').first().click();
   await frame.getByText('No clients attached in this window.',{exact:true}).waitFor();
   fresh=true;
   await page.reload();
   await frame.locator('.row-label').first().click();
   await frame.locator('.detail-row').filter({hasText:'Test device'}).waitFor();
   assert.ok(indexRequests>=2, 'changing snapshot index must be fetched again');
   assert.match(await frame.locator('.expanded').innerText(),/This AP · RuckusAP/);
   assert.match(await frame.locator('.expanded').innerText(),/historical snapshots unavailable/);
   const report=page.frames().find(f=>f.url().includes('zd1200-network-monitor.html'));
   const geometry=await report.evaluate(()=>{
    const rect=s=>{const r=document.querySelector(s).getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}};
    const badge=getComputedStyle(document.querySelector('.nm-badge'));
    return {main:rect('.history-row > .lanes'),band:rect('.history-band'),detail:rect('.detail-lane'),badge:{color:badge.color,background:badge.backgroundColor},air:rect('.airtime'),snrBottom:document.querySelector('.cell').getBoundingClientRect().top+50};
   });
   for(const lane of [geometry.band,geometry.detail]){assert.ok(Math.abs(lane.left-geometry.main.left)<1);assert.ok(Math.abs(lane.right-geometry.main.right)<1)}
   assert.notEqual(geometry.badge.color,geometry.badge.background);
   assert.ok(geometry.air.top>geometry.snrBottom);
   assert.match(await frame.locator('.row-label').innerText(),/Location: Kitchen/);
   await page.locator('#zd1200-ping-monitor-frame').evaluate(e=>{e.parentElement.style.cssText='position:fixed;top:calc(100vh - 320px);left:0;right:0';e.style.height='320px'});
   await frame.getByRole('button',{name:'Chart legend',exact:true}).click();
   assert.equal(await frame.getByText('What the history shows',{exact:true}).isVisible(),true);
   await frame.getByRole('button',{name:'Display and monitoring settings',exact:true}).click();
   assert.equal(await frame.getByText('What the history shows',{exact:true}).isVisible(),false);
   assert.equal(await frame.getByLabel('Collection interval').isVisible(),true);
   const pop=await frame.locator('#gear-pop').evaluate(e=>({bottom:e.getBoundingClientRect().bottom,viewport:innerHeight,height:e.clientHeight,scroll:e.scrollHeight}));
   assert.ok(pop.bottom<=pop.viewport);assert.ok(pop.scroll>pop.height);
   await frame.locator('#settings-apply').scrollIntoViewIfNeeded();
   const apply=await frame.locator('#settings-apply').boundingBox();const frameBox=await page.locator('#zd1200-ping-monitor-frame').boundingBox();
   assert.ok(apply.y+apply.height<=frameBox.y+frameBox.height);
   await frame.getByRole('button',{name:'Display and monitoring settings',exact:true}).click();
   await frame.getByRole('button',{name:'Devices',exact:true}).click();
   await frame.locator('.row-label').first().click();
   await frame.getByText('Attached AP · RuckusAP',{exact:true}).waitFor();
   assert.match(await frame.locator('.row-label').innerText(),/192.168.222.102/);
   assert.match(await frame.locator('.row-label').innerText(),/Location: Office/);
   const label=await frame.locator('.row-label').evaluate(e=>{const name=e.querySelector('.row-name').getBoundingClientRect(),sub=e.querySelector('.row-sub').getBoundingClientRect();return {nameBottom:name.bottom,subTop:sub.top}});
   assert.ok(label.subTop>=label.nameBottom);
   assert.match(await frame.locator('.history-band').innerText(),/RuckusAP · rzd · 5 GHz · ch 124/);
   const cells=await frame.locator('.history-row > .lanes > .cell').evaluateAll(nodes=>nodes.filter(n=>n.querySelector('.snr-fill')).map(n=>({title:n.title,height:parseFloat(n.querySelector('.snr-fill').style.height),fill:n.querySelector('.snr-fill').getBoundingClientRect().top,axis:n.querySelector('.baseline').getBoundingClientRect().top,cap:n.querySelector('.snr-cap').getBoundingClientRect().top})));
   assert.equal(cells.length,5);
   for(let i=0;i<snrs.length;i++){
    const expected=Math.max(0,40-snrs[i])*17/40;
    assert.equal(cells[i].height,expected);
    assert.ok(cells[i].fill>=cells[i].axis);
    assert.ok(cells[i].cap>=cells[i].axis);
   }
   console.log(`${name}: short-iframe popups scroll; labels do not overlap; timelines align; airtime is separate; stale snapshot index refreshes; AP/client paths and SNR geometry correct.`);
  }finally{await browser.close()}
 }
})().catch(e=>{console.error(e);process.exitCode=1}).finally(()=>server.close());
