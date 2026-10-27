/* Integrated additions to the existing offline viewer. No external assets. */
'use strict';
document.head.insertAdjacentHTML('beforeend','<style>[hidden]{display:none!important}</style>');
let workspaceSession=null,workspaceLive=false,manualPoints=new Set(),impactTime=null,replayDraft=null;
const maximum=(values,initial=0)=>values.reduce((a,b)=>Math.max(a,b),initial),minimum=values=>values.reduce((a,b)=>Math.min(a,b),Infinity);
const intro=document.querySelector('.intro p');
document.querySelector('.sidebar .card').hidden=true;
document.querySelector('.badge').textContent='LOCAL WORKBENCH';
document.querySelector('.intro h1').textContent='Inspect radar-relative detections';
document.querySelector('.table-card th:last-child').insertAdjacentHTML('afterend','<th>Noise (dB)</th>');
$('trail').value='0';
$('vmin').parentElement.insertAdjacentHTML('beforeend','<label class="label" for="vmax">Maximum |radial velocity| (m/s)</label><input id="vmax" type="number" value="1000000" min="0" step="0.1">');
for(const [id,title,unit] of [['countPlot','Detection count per frame','count'],['snrPlot','SNR over time','dB']]){const section=document.createElement('section');section.className='card plot-card';section.innerHTML=`<div class="plot-title"><h2>${title}</h2><span class="tag">${unit} · click to seek</span></div><canvas class="timeline" id="${id}" aria-label="${title}"></canvas>`;document.querySelector('.plots').append(section);}
const controls=document.createElement('section');controls.className='card';controls.style.marginTop='14px';controls.innerHTML=`<h2>Manual shot hypothesis & interval analysis</h2><p class="hint">Select a point by clicking a dot or row, then add it as a ball candidate. Points have no persistent IDs. Use previous/next frame to build your own hypothesis.</p><div class="pair"><label>Seek to time (s)<input id="seekSeconds" type="number" step="0.02" min="0" value="0"></label><label>Suspected impact (s)<input id="impact" type="number" step="0.02" min="0" placeholder="Not marked"></label></div><div class="player-top" style="flex-wrap:wrap;margin:12px 0"><button id="seekAt">Seek time</button><button id="markImpact">Impact = current frame</button><button id="intervalStart">Interval start = current</button><button id="intervalEnd">Interval end = current</button><button id="addCandidate">Add / remove selected candidate</button><button id="clearCandidates">Clear candidates</button></div><p class="hint">Flight interval uses the From / To time fields in Inspection filters. The analysis and CSV respect these display filters; they never modify radar CFAR.</p><div id="candidates" class="activity"></div><div class="player-top" style="flex-wrap:wrap;margin:12px 0"><button id="saveAnnotations">Save annotations</button><button id="reloadAnnotations">Reload annotations</button><button id="analyzeInterval" class="primary">Analyze selected interval</button><button id="manualCSV">Export candidate points · CSV</button></div><p id="annotationStatus" class="hint"></p><div id="analysisResult"></div><details><summary>Exact recorded console log</summary><pre id="recordedConsole"></pre></details>`;
document.querySelector('.table-card').after(controls);
const basePasses=passes;passes=p=>basePasses(p)&&Math.abs(p.v)<=+$('vmax').value;
const originalAxes=axes;axes=function(canvas,xmin,xmax,...args){if(workspaceLive&&recording&&['velocity','range','countPlot','snrPlot'].includes(canvas.id))xmin=recording.frames[0].t;return originalAxes(canvas,xmin,xmax,...args);};
$('vmax').onchange=()=>{stop();rebuild();};
const baseRender=render;
render=function(){baseRender();if(!recording||!filter)return;const f=recording.frames[index];$('seek').value=f.t*1000;
 const cells=Array.from($('rows').children);let k=0;f.points.forEach((p,j)=>{if(f.t<filter.from||f.t>filter.to||!passes(p))return;const row=cells[k++];if(!row)return;const td=document.createElement('td');td.textContent=fmt(p.noise,3);row.append(td);if(manualPoints.has(`${index}:${j}`))row.style.outline='1px solid #f3d47b';});
 const countMax=maximum(recording.frames.map(f=>f.points.length),1);const a=axes($('countPlot'),0,recording.summary.duration_s,0,countMax,'time (s)','detections / frame');const snrs=filtered.filter(r=>r.p.snr!==null);const b=axes($('snrPlot'),0,recording.summary.duration_s,0,maximum(snrs.map(r=>r.p.snr),10),'time (s)','SNR (dB)');charts.countPlot=a;charts.snrPlot=b;
 for(const frame of recording.frames){a.ctx.fillStyle='#62d9c8';a.ctx.fillRect(a.px(frame.t)-1,a.py(frame.points.length),2,a.bottom-a.py(frame.points.length));}for(const r of snrs){b.ctx.fillStyle=color(r.p);b.ctx.beginPath();b.ctx.arc(b.px(r.f.t),b.py(r.p.snr),2.5,0,Math.PI*2);b.ctx.fill();}for(const chart of [a,b]){chart.ctx.strokeStyle='#fff';chart.ctx.beginPath();chart.ctx.moveTo(chart.px(f.t),chart.top);chart.ctx.lineTo(chart.px(f.t),chart.bottom);chart.ctx.stroke();}
};
const originalLoad=loadRecording;loadRecording=function(r){manualPoints.clear();impactTime=null;originalLoad(r);$('seek').max=Math.ceil(r.summary.duration_s*1000);$('seek').step=1;$('seek').value=0;};
const originalReset=resetFilters;resetFilters=function(){$('vmax').value=1000000;originalReset();$('trail').value='0';rebuild();};$('reset').onclick=resetFilters;
function seekTime(t){if(!recording)return;let best=0;recording.frames.forEach((f,i)=>{if(Math.abs(f.t-t)<Math.abs(recording.frames[best].t-t))best=i;});seek(best);}
$('seek').oninput=()=>seekTime(+$('seek').value/1000);$('seekAt').onclick=()=>seekTime(+$('seekSeconds').value);
for(const id of ['countPlot','snrPlot'])$(id).onclick=e=>{if(!recording)return;const a=charts[id],x=e.clientX-$(id).getBoundingClientRect().left;seekTime(Math.max(0,(x-a.left)/(a.right-a.left)*recording.summary.duration_s));};
function annotationStatus(message){$('annotationStatus').textContent=message;}
function renderCandidates(){$('candidates').replaceChildren();for(const ref of manualPoints){const [i,j]=ref.split(':').map(Number),f=recording.frames[i];if(!f?.points[j])continue;const b=document.createElement('button');b.textContent=`${f.t.toFixed(3)} s · frame ${f.number} · point ${j}`;b.onclick=()=>{seek(i);selected=j;render();};$('candidates').append(b);}annotationStatus(`${manualPoints.size} manually selected ball candidate points. ${workspaceSession?'Annotations can be saved to this session.':'Demo: import this recording as a session to persist annotations.'}`);}
$('addCandidate').onclick=()=>{if(workspaceLive){error('Stop recording and open a saved session to annotate.');return;}if(!recording?.frames[index]?.points[selected]){error('Select a current-frame point first.');return;}const key=`${index}:${selected}`;if(manualPoints.has(key))manualPoints.delete(key);else manualPoints.add(key);renderCandidates();render();};
$('clearCandidates').onclick=()=>{manualPoints.clear();renderCandidates();render();};
$('markImpact').onclick=()=>{if(!recording)return;impactTime=recording.frames[index].t;$('impact').value=impactTime.toFixed(3);};
$('impact').onchange=()=>{impactTime=$('impact').value===''?null:+$('impact').value;};
for(const [button,field] of [['intervalStart','from'],['intervalEnd','to']])$(button).onclick=()=>{if(!recording)return;$(field).value=recording.frames[index].t.toFixed(3);rebuild();};
function selectionBody(manual_only=false){return {impact_s:impactTime,from_s:+$('from').value,to_s:+$('to').value,points:[...manualPoints].map(r=>r.split(':').map(Number)),filters:{rmin:+$('rmin').value,rmax:+$('rmax').value,vmin:+$('vmin').value,vmax:+$('vmax').value,snr:+$('snr').value,direction:$('direction').value},manual_only};}
function stashReplay(){if(!workspaceLive&&recording)replayDraft={sessionId:workspaceSession,annotations:selectionBody(),index};}
async function viewerAPI(path,method,body){const response=await fetch(path,{method,headers:{'Content-Type':'application/json','X-Radar-Local':'1'},body:body?JSON.stringify(body):undefined});if(!response.ok){const e=await response.json();throw Error(typeof e.detail==='string'?e.detail:JSON.stringify(e.detail));}return response;}
function restoreAnnotations(a){manualPoints=new Set((a?.points||[]).map(r=>r.join(':')));impactTime=a?.impact_s??null;$('impact').value=impactTime??'';if(a&&a.to_s>a.from_s){$('from').value=a.from_s;$('to').value=a.to_s;for(const [key,value] of Object.entries(a.filters||{}))if($(key))$(key).value=value;}renderCandidates();rebuild();}
function handler(id,fn){$(id).onclick=async()=>{try{error('');await fn();}catch(e){error(e.message);}};}
handler('saveAnnotations',async()=>{if(!workspaceSession)throw Error('Import this recording as a session before saving annotations.');await viewerAPI(`/api/sessions/${workspaceSession}/annotations`,'PUT',selectionBody());annotationStatus('Annotations saved. Original stream and CFG are unchanged.');});
handler('reloadAnnotations',async()=>{if(!workspaceSession)throw Error('Open a saved session first.');const r=await (await viewerAPI(`/api/sessions/${workspaceSession}`,'GET')).json();restoreAnnotations(r.annotations);});
handler('manualCSV',async()=>{if(!recording)return;const rows=[['frame_number','time_s','point_index','x_m','y_m','z_m','range_m','radial_velocity_mps','snr_db','noise_db']];for(const {p,f,i,j} of filtered)if(manualPoints.has(`${i}:${j}`))rows.push([f.number,f.t,j,p.x,p.y,p.z,p.range,p.v,p.snr??'',p.noise??'']);download(rows.map(r=>r.join(',')).join('\r\n'),'manual_candidate_points.csv','text/csv');});
function statBlock(title,s){const section=document.createElement('section'),h=document.createElement('h3');h.textContent=title;section.append(h);const p=document.createElement('p');p.textContent=`${s.detection_count} detections · interval duration ${fmt(s.duration_s,3)} s`;section.append(p);for(const [key,label] of [['range_m','Range (m)'],['snr_db','SNR (dB)'],['reported_radial_velocity_mps','Reported signed radial velocity (m/s)']]){const p=document.createElement('p'),v=s[key];p.textContent=label+': '+(v?`min ${fmt(v.min,3)} · max ${fmt(v.max,3)} · mean ${fmt(v.mean,3)} · median ${fmt(v.median,3)}`:'not provided');section.append(p);}return section;}
handler('analyzeInterval',async()=>{if(workspaceLive)throw Error('Open a saved replay to analyze an interval.');if(!recording)return;const path=workspaceSession?`/api/sessions/${workspaceSession}/analysis`:'/api/demo/analysis';const result=await (await viewerAPI(path,'POST',selectionBody())).json();$('analysisResult').replaceChildren(statBlock('All detections in this interval (viewer filters applied)',result.all_detections_in_interval),statBlock('Manually selected ball candidate points',result.manually_selected_ball_candidates));const fit=result.motion_estimate,p=document.createElement('p');p.className='warning';p.textContent=fit?`${fit.label}. Mean velocity [x,y,z] = [${fit.velocity_xyz_mps.map(v=>fmt(v,3)).join(', ')}] m/s; magnitude ${fmt(fit.mean_speed_mps,3)} m/s. Direction unit vector: [${fit.direction_unit_xyz?.map(v=>fmt(v,3)).join(', ')||'undefined (stationary)'}]. Position fit RMS residual ${fmt(fit.rms_position_residual_m,4)} m; maximum ${fmt(fit.max_position_residual_m,4)} m. ${fit.point_count} points over ${fmt(fit.duration_s,3)} s. Identity remains unverified. Radial velocity is not full 3D speed. Poor geometry or associations can make this estimate misleading.`:'Motion estimate unavailable: select at least four candidate points in distinct frames, one per frame, at distinct times. A fit over an interval is not launch speed.';$('analysisResult').append(p);});
function makeLive(payload){const frames=payload.frames;if(!frames.length||!payload.config)return;const points=frames.flatMap(f=>f.points),values=points.map(p=>p.range),speeds=points.map(p=>p.v),snrs=points.filter(p=>p.snr!==null).map(p=>p.snr);return {data_name:'LIVE · bounded recent history',cfg_name:'Successfully applied CFG snapshot',cfg_text:payload.cfg_text,config:payload.config,frames,activity:[],diagnostics:{...payload.diagnostics,tlv_counts:{}},summary:{frames:frames.length,points:points.length,nonempty_frames:frames.filter(f=>f.points.length).length,duration_s:frames.at(-1).t+payload.config.frame_period_ms/1000,range_m:values.length?[minimum(values),maximum(values)]:null,radial_velocity_mps:speeds.length?[minimum(speeds),maximum(speeds,-Infinity)]:null,highest_reported_speed_mps:speeds.length?maximum(speeds.map(Math.abs)):null,snr_points:snrs.length}};}
window.addEventListener('message',e=>{
 if(e.origin!==location.origin||e.source!==parent)return;
 const m=e.data;
 if(m.type==='mode'){stop();return;}
 if(m.type==='recording'){
  stashReplay();
  const draft=replayDraft?.sessionId===m.sessionId?replayDraft:null;
  workspaceLive=false;workspaceSession=m.sessionId;
  document.querySelector('.layout').hidden=false;document.querySelector('.kpis').hidden=false;
  intro.textContent=m.sessionId?'SAVED REPLAY · timing from exact recorded CFG, including missing-frame gaps.':'DEMO REPLAY · real recorded data, independent of hardware.';
  $('recordedConsole').textContent=m.console||'(No console log)';$('analysisResult').replaceChildren();
  loadRecording(m.recording);restoreAnnotations(draft?.annotations||m.annotations);
  if(draft)seek(draft.index);
  document.querySelector('.player').hidden=false;
 }
 if(m.type==='live'){
  stashReplay();const wasLive=workspaceLive;workspaceLive=true;workspaceSession=null;stop();
  const r=makeLive(m);
  intro.textContent=r?'LIVE VIEW · latest 500 decoded frames only. Display updates may be dropped; backend recording retains all received bytes.':'LIVE VIEW · no frames with a known applied configuration. Connect, apply a CFG, and start the sensor. Hardware status is shown above.';
  document.querySelector('.layout').hidden=!r;document.querySelector('.kpis').hidden=!r;
  document.querySelector('.player').hidden=true;
  if(!r){recording=null;return;}
  if(!wasLive||!recording){loadRecording(r);$('trail').value='0';}
  else{recording=r;index=r.frames.length-1;selected=-1;$('from').value=r.frames[0].t;$('to').value=r.summary.duration_s;$('duration').textContent=fmt(r.summary.duration_s)+' s';$('frames').textContent=r.frames.length;$('points').textContent=r.summary.points;$('maxspeed').textContent=fmt(r.summary.highest_reported_speed_mps)+' m/s';rebuild();}
  index=r.frames.length-1;render();
 }
});
new ResizeObserver(()=>parent.postMessage({type:'height',height:Math.ceil(document.body.getBoundingClientRect().height)},location.origin)).observe(document.body);
parent.postMessage({type:'ready'},location.origin);
