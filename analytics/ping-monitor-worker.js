'use strict';

const MAGIC=[0x5a,0x44,0x50,0x4d,0x44,0x41,0x59,0x00];

function macAt(bytes,offset){
 const hex=[];for(let i=0;i<6;i++)hex.push(bytes[offset+i].toString(16).padStart(2,'0'));
 return hex.join(':');
}

function parseDay(buffer){
 const bytes=new Uint8Array(buffer),view=new DataView(buffer);
 if(bytes.length<576||!MAGIC.every((value,index)=>bytes[index]===value))throw new Error('Invalid Performance History daily file magic.');
 const version=view.getUint16(8,true),headerSize=view.getUint16(10,true),flags=view.getUint32(12,true);
 const start=view.getUint32(16,true),end=view.getUint32(20,true),roundCount=view.getUint32(24,true),targetCount=view.getUint32(28,true);
 const timeout=view.getUint16(32,true),codeCount=view.getUint16(34,true),timestampsOffset=view.getUint32(36,true);
 const macsOffset=view.getUint32(40,true),samplesOffset=view.getUint32(44,true),generation=view.getUint32(48,true);
 if(![1,2].includes(version)||headerSize!==(version===1?576:640)||codeCount!==254||end-start!==86400)throw new Error('Unsupported Performance History daily format.');
 if(version===1&&flags!==1)throw new Error('Unsupported Performance History daily flags.');
 const matrixSize=targetCount*roundCount;
 let snrOffset=0,stateOffset=0,apCount=0,apMacsOffset=0,air24Offset=0,air5Offset=0,meshSnrOffset=0,fileEnd=samplesOffset+matrixSize;
 if(version===2){
  if(flags!==31)throw new Error('Unsupported Performance History telemetry flags.');
  snrOffset=view.getUint32(52,true);stateOffset=view.getUint32(56,true);apCount=view.getUint32(60,true);
  apMacsOffset=view.getUint32(64,true);air24Offset=view.getUint32(68,true);air5Offset=view.getUint32(72,true);
  meshSnrOffset=view.getUint32(76,true);fileEnd=view.getUint32(80,true);
  if(snrOffset!==samplesOffset+matrixSize||stateOffset!==snrOffset+matrixSize||apMacsOffset<stateOffset+matrixSize||air24Offset<apMacsOffset+apCount*6||air5Offset!==air24Offset+apCount*roundCount||meshSnrOffset!==air5Offset+apCount*roundCount||fileEnd!==meshSnrOffset+apCount*roundCount)throw new Error('Invalid Performance History telemetry offsets.');
 }
 if(timestampsOffset!==headerSize||macsOffset!==timestampsOffset+roundCount*4||samplesOffset<macsOffset+targetCount*6||fileEnd!==bytes.length)throw new Error('Invalid Performance History daily offsets.');
 const codebookOffset=version===1?64:132,codebook=new Uint16Array(codeCount);let previous=0;
 for(let i=0;i<codeCount;i++){let value=view.getUint16(codebookOffset+i*2,true);if(value<=previous||value>timeout)throw new Error('Invalid Performance History latency codebook.');codebook[i]=value;previous=value}
 const timestamps=new Uint32Array(roundCount);previous=0;
 for(let i=0;i<roundCount;i++){let value=view.getUint32(timestampsOffset+i*4,true);if((i&&value<=previous)||value<start||value>=end)throw new Error('Invalid Performance History round timestamps.');timestamps[i]=value;previous=value}
 const macs=new Array(targetCount);let previousMac='';
 for(let i=0;i<targetCount;i++){let value=macAt(bytes,macsOffset+i*6);if(previousMac&&value<=previousMac)throw new Error('Invalid Performance History target order.');macs[i]=value;previousMac=value}
 const apMacs=new Array(apCount);previousMac='';
 for(let i=0;i<apCount;i++){let value=macAt(bytes,apMacsOffset+i*6);if(previousMac&&value<=previousMac)throw new Error('Invalid Performance History AP order.');apMacs[i]=value;previousMac=value}
 return{version,bytes,codebook,start,end,generation,roundCount,targetCount,timestamps,macs,samplesOffset,snrOffset,stateOffset,apCount,apMacs,air24Offset,air5Offset,meshSnrOffset};
}

async function fetchDay(file,cacheKey){
 const suffix=file.immutable?`?revision=${encodeURIComponent(file.revision||file.bytes||1)}`:`?generation=${encodeURIComponent(cacheKey)}`;
 const response=await fetch(`zd1200-ping-monitor-daily/${file.file}${suffix}`,{cache:file.immutable?'force-cache':'no-store'});
 if(!response.ok)throw new Error(`Unable to load ${file.file}: HTTP ${response.status}`);
 const compressed=await response.arrayBuffer();
 if(typeof DecompressionStream==='undefined')throw new Error('This browser cannot decompress Performance History data.');
 const stream=new Blob([compressed]).stream().pipeThrough(new DecompressionStream('gzip'));
 return parseDay(await new Response(stream).arrayBuffer());
}

async function history(job){
 const targetIndex=new Map(job.targetMacs.map((mac,index)=>[mac,index])),targetCount=job.targetMacs.length;
 const buckets=Math.ceil((job.rangeEnd-job.rangeStart)/job.bucketSeconds),cells=targetCount*buckets;
 const attempts=new Uint32Array(cells),replies=new Uint32Array(cells),latencySum=new Uint32Array(cells),latencyMax=new Uint16Array(cells);
 const snrSum=new Uint32Array(cells),snrCount=new Uint16Array(cells),snrMin=new Uint8Array(cells);snrMin.fill(255);
 const associated=new Uint16Array(cells),associatedAt=new Uint32Array(cells),known=new Uint16Array(cells),airtimeSum=new Uint32Array(cells),airtimeCount=new Uint16Array(cells);
 const meshSnrMin=new Uint8Array(cells);meshSnrMin.fill(255);
 let completed=0;
 for(const file of job.files){
  const day=await fetchDay(file,job.generation);
  for(let source=0;source<day.targetCount;source++){
   const target=targetIndex.get(day.macs[source]);if(target===undefined)continue;
   const base=day.samplesOffset+source*day.roundCount,snrBase=day.snrOffset+source*day.roundCount,stateBase=day.stateOffset+source*day.roundCount;
   for(let round=0;round<day.roundCount;round++){
    const timestamp=day.timestamps[round];if(timestamp<job.rangeStart||timestamp>=job.rangeEnd)continue;
    const bucket=Math.floor((timestamp-job.rangeStart)/job.bucketSeconds),cell=target*buckets+bucket,code=day.bytes[base+round];
    const state=day.version===1?(code?1:0):day.bytes[stateBase+round];if(state){known[cell]++;if(state===1){associated[cell]++;associatedAt[cell]=timestamp}}
    if(code){attempts[cell]++;if(code!==255){const latency=day.codebook[code-1];replies[cell]++;latencySum[cell]+=latency;if(latency>latencyMax[cell])latencyMax[cell]=latency}}
    if(day.version===2){const snrCode=day.bytes[snrBase+round];if(snrCode){const snr=snrCode-1;snrSum[cell]+=snr;snrCount[cell]++;if(snr<snrMin[cell])snrMin[cell]=snr}}
   }
  }
  if(day.version===2)for(let source=0;source<day.apCount;source++){
   const target=targetIndex.get(day.apMacs[source]);if(target===undefined)continue;
   const airBase=(job.band==='g'?day.air24Offset:day.air5Offset)+source*day.roundCount,meshBase=day.meshSnrOffset+source*day.roundCount;
   for(let round=0;round<day.roundCount;round++){
    const timestamp=day.timestamps[round];if(timestamp<job.rangeStart||timestamp>=job.rangeEnd)continue;
    const bucket=Math.floor((timestamp-job.rangeStart)/job.bucketSeconds),cell=target*buckets+bucket,air=day.bytes[airBase+round],mesh=day.bytes[meshBase+round];
    if(air){airtimeSum[cell]+=air-1;airtimeCount[cell]++}if(mesh&&mesh-1<meshSnrMin[cell])meshSnrMin[cell]=mesh-1;
   }
  }
  completed++;postMessage({type:'progress',id:job.id,completed,total:job.files.length});
 }
 return{type:'history',id:job.id,buckets,attempts,replies,latencySum,latencyMax,snrSum,snrCount,snrMin,associated,associatedAt,known,airtimeSum,airtimeCount,meshSnrMin};
}

self.onmessage=event=>{
 const job=event.data;if(!job||job.type!=='history')return;
 history(job).then(result=>postMessage(result)).catch(error=>postMessage({type:'error',id:job.id,message:error.message}));
};
