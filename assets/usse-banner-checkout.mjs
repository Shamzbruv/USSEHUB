import {BANNER_FORMATS,BANNER_PAGES,BANNER_POSITIONS,placementLabel} from './usse-banner-core.mjs';
let objectUrl;
function preview(){const frame=document.getElementById('adv-banner-preview'),size=document.getElementById('adv-banner-size')?.value;if(!frame||!BANNER_FORMATS[size])return;const format=BANNER_FORMATS[size];frame.style.aspectRatio=format.width+'/'+format.height;frame.style.maxWidth=size==='skyscraper'?'200px':'100%';const file=document.getElementById('adv-creative-file')?.files?.[0];if(!file)return;if(!['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm'].includes(file.type)||file.size>20*1024*1024)return;if(objectUrl)URL.revokeObjectURL(objectUrl);objectUrl=URL.createObjectURL(file);const media=document.createElement(file.type.startsWith('video/')?'video':'img');media.src=objectUrl;if(media.tagName==='VIDEO'){media.controls=true;media.muted=true;media.playsInline=true;}else{media.alt='Your uploaded banner artwork';media.onload=()=>{document.getElementById('adv-banner-preview-note').textContent=`Uploaded ${media.naturalWidth} × ${media.naturalHeight} px. ${format.name} artwork is recommended at ${format.width} × ${format.height} px. The preview keeps the complete image visible.`;};}frame.replaceChildren(media);}
document.addEventListener('change',event=>{if(['adv-banner-size','adv-creative-file'].includes(event.target.id))preview();});
const page=document.getElementById('banner-package-page'),position=document.getElementById('banner-package-position');
if(page&&position){
 for(const[k,v]of Object.entries(BANNER_PAGES))page.append(new Option(v,k));
 for(const[k,v]of Object.entries(BANNER_POSITIONS))position.append(new Option(v,k));
 const input=document.getElementById('package-placements'),type=document.getElementById('package-type'),button=document.getElementById('banner-add-placement');
 function updatePlacementSummary(){
  const banner=type.value==='display_ad';
  document.getElementById('banner-position-fields').hidden=!banner;
  document.getElementById('webpage-placement-note').hidden=banner;
  button.disabled=!banner;
  const summary=document.getElementById('banner-placement-summary');summary.replaceChildren();
  const keys=[...new Set(input.value.split(',').map(s=>s.trim()).filter(Boolean))];
  for(const key of keys){const chip=document.createElement('span');chip.className='banner-placement-chip';chip.textContent=placementLabel(key);summary.append(chip);}
  if(!keys.length)summary.textContent='No positions selected yet. Choose a page and position, then select Add position.';
 }
 button.onclick=()=>{if(type.value!=='display_ad')return;input.value=[...new Set([...input.value.split(',').map(s=>s.trim()).filter(Boolean),page.value+'-'+position.value])].join(', ');updatePlacementSummary();};
 input.addEventListener('input',updatePlacementSummary);type.addEventListener('change',updatePlacementSummary);document.addEventListener('usse:package-form-open',updatePlacementSummary);updatePlacementSummary();
}
window.addEventListener('pagehide',()=>{if(objectUrl)URL.revokeObjectURL(objectUrl);});
