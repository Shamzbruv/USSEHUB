import {mountAjmAdDelivery} from './ajm-ad-delivery.mjs';
import {BANNER_FORMATS,bannerFormat} from './usse-banner-core.mjs';
const page=document.body.dataset.hubPage,prefix={index:'home','ajm-advertising-hub':'hub','ajm-aloe-jamaica':'aloe','usse-consultancy':'consultancy','pistol-operations-logistics':'pistol','ajm-business-page':'business','ajm-jobzone':'jobs','ajm-marketplace':'marketplace'}[page];
if(prefix){
 const main=document.querySelector('main')||document.querySelector('.hub-layout'),header=document.querySelector('header,.topbar'),footer=document.querySelector('footer');
 if(main){let stage;const jobs=['top','bottom','left','right'].map(async position=>{const mount=document.createElement('aside');mount.hidden=true;mount.className='ajm-ad-network-mount usse-banner-slot';mount.dataset.position=position;mount.setAttribute('aria-label','Sponsored banner · '+position);if(position==='top'){if(header)header.after(mount);else main.before(mount);}else if(position==='bottom'){if(footer)footer.before(mount);else main.after(mount);}else main.after(mount);
  const placement=prefix+'-'+position,ad=await mountAjmAdDelivery({target:mount,placement:[placement,...(prefix==='home'&&position==='top'?['home-hero','home-featured']:[])],pageKey:page});
  if(!ad){mount.remove();return;}const tile=mount.querySelector('.ajm-network-ad');if(tile){tile.classList.add('usse-display-banner');const f=BANNER_FORMATS[bannerFormat(ad)];tile.style.setProperty('--banner-aspect',f.width+'/'+f.height);}
  if(position==='left'||position==='right'){if(!stage){stage=document.createElement('div');stage.className='usse-banner-stage';main.before(stage);stage.append(main);}mount.classList.add('usse-banner-'+position);stage.classList.add('has-'+position);if(position==='left')stage.prepend(mount);else stage.append(mount);}
 });await Promise.allSettled(jobs);}
}
