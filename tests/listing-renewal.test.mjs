import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { PGlite } from '@electric-sql/pglite';
const html=fs.readFileSync('ajm-admin-panel.html','utf8');
assert.match(html,/window\.renewFreeListing\s*=\s*renewFreeListing;/,'Inline renewal button must be wired to the module function');
assert.match(html,/onclick="renewFreeListing\('\$\{l.id\}', this\)"/,'Renewal must receive its clicked button');
const source=html.slice(html.indexOf('    const renewingFreeListings = new Set();'),html.indexOf('    async function updateListingStatus'));
const id='11111111-1111-4111-8111-111111111111';
let calls=0, loads=0, stats=0, toasts=[], result, release;
const context=vm.createContext({
  supabase:{rpc:async(name,payload)=>{assert.equal(name,'renew_free_listing');assert.equal(payload.p_listing_id,id);calls++;return await new Promise(resolve=>release=()=>resolve(result));}},
  showToast:(...args)=>toasts.push(args),fmtDate:v=>v,
  loadListings:async()=>loads++,loadStats:async()=>stats++
});
vm.runInContext(source,context);
function button(){return{disabled:false,textContent:'↻ 30d',setAttribute(k,v){this[k]=v;},removeAttribute(k){delete this[k];}};}
const b=button();result={data:{listing_id:id,status:'approved',expires_at:'2026-11-25T12:00:00Z'},error:null};
const pending=context.renewFreeListing(id,b);
assert.equal(b.disabled,true);assert.equal(b['aria-busy'],'true');
await context.renewFreeListing(id,b);assert.equal(calls,1,'Repeated clicks must not renew twice');
release();await pending;
assert.equal(loads,1);assert.equal(stats,1);assert.equal(toasts[0][1],'success');assert.equal(b.disabled,false);assert.equal(b.textContent,'↻ 30d');assert.equal(b['aria-busy'],undefined);
for(const response of [{data:null,error:{message:'Access denied'}},{data:null,error:null},{data:{listing_id:id,status:'expired',expires_at:'invalid'},error:null}]){
 result=response;toasts=[];const p=context.renewFreeListing(id,b);release();await p;
 assert.equal(toasts[0][1],'error');assert.equal(b.disabled,false);assert.equal(loads,1,'An unconfirmed renewal cannot be reported as success');
}
// Run the exact deployed SQL function locally, with the same authorization gates.
const db=new PGlite();
await db.exec(`CREATE SCHEMA auth;CREATE SCHEMA private;CREATE ROLE anon;CREATE ROLE authenticated;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.test_uid',true),'')::uuid $$;
CREATE TABLE public.listings(id uuid PRIMARY KEY,owner_user_id uuid,status text,expires_at timestamptz,published_at timestamptz);
CREATE TABLE public.listing_status_history(listing_id uuid,old_status text,new_status text,changed_by uuid,reason text);
CREATE FUNCTION private.is_admin(uid uuid) RETURNS boolean LANGUAGE sql AS $$ SELECT uid='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid $$;`);
const sql=fs.readFileSync('supabase/migrations/20260824000000_order_admin_and_listing_lifecycle.sql','utf8');
await db.exec(sql.slice(sql.indexOf('CREATE OR REPLACE FUNCTION public.renew_free_listing('),sql.indexOf('-- ---------------------------------------------------------------------------\n-- 5.')));
const owner='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',admin='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
await db.exec(`INSERT INTO listings VALUES('${id}','${owner}','expired',now()-interval '1 day',now()-interval '40 days');`);
async function renewAs(uid){await db.exec(`SELECT set_config('request.test_uid','${uid}',false);`);return db.query(`SELECT public.renew_free_listing('${id}') result;`);}
await assert.rejects(()=>renewAs(''),/signed in/);
await assert.rejects(()=>renewAs('cccccccc-cccc-4ccc-8ccc-cccccccccccc'),/permission/);
for(const uid of [admin,owner]){
 const {rows}=await renewAs(uid);assert.equal(rows[0].result.status,'approved');
 const days=(Date.parse(rows[0].result.expires_at)-Date.now())/86400000;
 assert.ok(days>29.99&&days<30.01,'A renewal must start a fresh 30-day window');
}
const history=await db.query('SELECT * FROM listing_status_history');assert.equal(history.rows.length,1);
const permissions=await db.query("SELECT has_function_privilege('authenticated','public.renew_free_listing(uuid)','EXECUTE') member,has_function_privilege('anon','public.renew_free_listing(uuid)','EXECUTE') anon");
assert.equal(permissions.rows[0].member,true);assert.equal(permissions.rows[0].anon,false);
await db.close();
console.log('Listing renewal passed: real click wiring, in-flight protection, success/error feedback, 30-day expiry and database authorization.');
