import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {bannerPlacementDraft} from '../assets/usse-banner-placement-core.mjs';
import {BANNER_PAGES,BANNER_POSITIONS} from '../assets/usse-banner-core.mjs';
const pkg={id:'banner-fixture',product_type:'display_ad',placements:['home-top','legacy-slot']};
assert.deepEqual(bannerPlacementDraft(pkg,'hub','left'),['home-top','legacy-slot','hub-left']);
assert.deepEqual(bannerPlacementDraft(pkg,'home','top'),pkg.placements);assert.deepEqual(pkg.placements,['home-top','legacy-slot']);
for(const page of Object.keys(BANNER_PAGES))for(const position of Object.keys(BANNER_POSITIONS))assert.deepEqual(bannerPlacementDraft(null,page,position),[page+'-'+position]);
assert.throws(()=>bannerPlacementDraft({product_type:'webpage'},'hub','left'),/display-ad package/);assert.throws(()=>bannerPlacementDraft(null,'constructor','left'),/supported/);assert.throws(()=>bannerPlacementDraft(null,'hub','anywhere'),/supported/);
const html=fs.readFileSync(new URL('../ajm-ad-management.html',import.meta.url),'utf8');
const nodes=Object.fromEntries(['banner-planner-package','banner-planner-page','package-placements','banner-package-page','banner-package-position'].map(id=>[id,{value:''}]));nodes['banner-planner-package'].value=pkg.id;nodes['banner-planner-page'].value='hub';nodes['banner-placement-planner']={elements:{position:{value:'right'}}};
let opened=0,notices=[],events=[];
const scope={state:{packages:[pkg]},el:id=>nodes[id],bannerPlacementDraft,BANNER_PAGES,BANNER_POSITIONS,openPackageForm(value){assert.equal(value,pkg);opened++;},showNotice:(...args)=>notices.push(args),document:{dispatchEvent:e=>events.push(e.type)},Event:class{constructor(type){this.type=type;}}};
vm.createContext(scope);vm.runInContext(html.slice(html.indexOf('        function prepareBannerPlacement(event)'),html.indexOf('        function populateAccountSelect')),scope);scope.prepareBannerPlacement({preventDefault(){}});
assert.equal(opened,1);assert.equal(nodes['package-placements'].value,'home-top, legacy-slot, hub-right');assert.equal(nodes['banner-package-page'].value,'hub');assert.equal(nodes['banner-package-position'].value,'right');assert.match(notices.at(-1)[1],/draft/);assert.deepEqual(events,['usse:package-form-open']);assert.deepEqual(pkg.placements,['home-top','legacy-slot'],'preparing a position must not mutate a package before Save');
scope.state.packages=[{...pkg,product_type:'webpage'}];scope.prepareBannerPlacement({preventDefault(){}});assert.equal(opened,1);assert.match(notices.at(-1)[1],/display-ad package/);
// Exercise the production modal lifecycle: focus moves inside, then returns,
// and the document's prior scroll state is restored after dismissal.
const classes=new Set(),previous={isConnected:true,focus(){doc.activeElement=this;}},close={focus(){doc.activeElement=this;},offsetParent:{}},last={focus(){doc.activeElement=this;},offsetParent:{}},body={scrollTop:99};
const modal={classList:{add:c=>classes.add(c),remove:c=>classes.delete(c)},querySelector:s=>s==='.modal-body'?body:close,querySelectorAll:()=>[close,last],contains:node=>node===close||node===last};
modal.closest=()=>modal;
const doc={activeElement:previous,body:{style:{overflow:'auto'}},querySelector:()=>classes.has('open')?modal:null,querySelectorAll:()=>classes.has('open')?[modal]:[],addEventListener:(type,fn)=>{doc.keydown=fn;}};
const modScope={document:doc,el:()=>modal};vm.createContext(modScope);vm.runInContext(html.slice(html.indexOf('        const modalReturnFocus'),html.indexOf('        async function adminCommand')),modScope);
const keyStart=html.indexOf("        document.addEventListener('keydown', (event) => {");const keyEnd=html.indexOf("        document.addEventListener('click', async (event)",keyStart);
vm.runInContext(html.slice(keyStart,keyEnd),modScope);modScope.openModal('package-modal');assert.equal(doc.activeElement,close);assert.equal(body.scrollTop,0);assert.equal(doc.body.style.overflow,'hidden');doc.activeElement=last;let prevented=false;doc.keydown({key:'Tab',preventDefault(){prevented=true;}});assert(prevented);assert.equal(doc.activeElement,close);doc.keydown({key:'Escape',preventDefault(){}});assert.equal(doc.activeElement,previous);assert.equal(doc.body.style.overflow,'auto');assert(!classes.has('open'));
console.log('Banner controls passed: supported positions, preserved placements, display-ad restriction, draft-only preparation, modal focus, keyboard containment and scroll restoration.');
