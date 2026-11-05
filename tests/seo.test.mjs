import assert from 'node:assert/strict';
import http from 'node:http';
import {createSiteServer,publicJobClient} from '../server.mjs';
import {schemaForJob,renderJob,jobPath,jsonLd} from '../server/seo-core.mjs';
const job={id:'11111111-1111-4111-8111-111111111111',title:'Operations coordinator',company_name:'Example employer',description:'Coordinate daily operations, support customer enquiries and work with the team to maintain accurate records and service standards.',requirements:'Experience coordinating schedules and excellent communication skills.',location:'Kingston, Jamaica',work_mode:'On-site',employment_type:'Full-time',created_at:new Date(Date.now()-86400000).toISOString(),closes_at:new Date(Date.now()+86400000).toISOString(),industry:'Operations',department:'Office',post_kind:'vacancy'};
const flyer={...job,id:'22222222-2222-4222-8222-222222222222',post_kind:'flyer',flyer_path:'33333333-3333-4333-8333-333333333333/44444444-4444-4444-8444-444444444444.png',flyer_deadline_known:false};
const schema=schemaForJob(job);assert.equal(schema.jobLocation.address.addressCountry,'JM');assert.equal(schema.hiringOrganization.name,job.company_name);assert.equal(schema.employmentType,'FULL_TIME');assert.equal(schema.baseSalary,undefined);assert.equal(schema.hiringOrganization.logo,undefined);
assert.equal(schemaForJob(flyer),null);assert.equal(schemaForJob({...job,location:'Kingston'}),null);assert.equal(schemaForJob({...job,description:'See flyer'}),null);assert.equal(schemaForJob({...job,closes_at:'2000-01-01'}),null);assert.equal(schemaForJob({...job,status:'closed'}),null);
assert.equal(schemaForJob({...job,work_mode:'Remote'}).applicantLocationRequirements.name,'Jamaica');
const hostile={...job,title:'</script><script>alert(1)</script>',description:'<img src=x onerror=alert(1)> '+job.description};const markup=renderJob(hostile);assert(!markup.includes('<img src=x'));assert(!markup.includes('</script><script>alert'));assert.equal(JSON.parse(jsonLd(hostile)).title,hostile.title);
let fail=false;const calls=[];const jobs={browse:async payload=>{calls.push(payload);if(fail)throw new Error('simulated outage');return{total:26,rows:payload.offset===25?[flyer]:[job,flyer]};},detail:async id=>id===job.id?job:id===flyer.id?flyer:null};
const requested=[];const fetchImpl=async(url,options)=>{requested.push([String(url),options]);return options?.method==='POST'?new Response(JSON.stringify({signedURL:'/object/sign/jobzone-vacancy-flyers/'+flyer.flyer_path+'?token=fixture'}),{headers:{'content-type':'application/json'}}):new Response(Buffer.from([137,80,78,71]),{headers:{'content-type':'image/png'}});};
const server=createSiteServer({jobs,fetchImpl});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin='http://127.0.0.1:'+server.address().port;const get=(url,options)=>fetch(origin+url,{redirect:'manual',...options});
try{
 let r=await get('/jobs');assert.equal(r.status,200);let html=await r.text();assert(html.includes('href="'+jobPath(job)+'"'));assert(html.includes(job.description));assert(!html.includes('"@type":"JobPosting"'));assert(html.includes('job-public-state'));assert(html.includes('https://ussehub.com/jobs'));
 r=await get(jobPath(job));assert.equal(r.status,200);html=await r.text();assert(html.includes('"@type":"JobPosting"'));assert(html.includes(job.requirements));assert(html.includes('detail-application'));assert.equal(r.headers.get('cache-control'),'no-store');
 r=await get(jobPath(job),{method:'HEAD'});assert.equal(r.status,200);assert.equal(await r.text(),'');
 r=await get('/jobs/'+job.id);assert.equal(r.status,308);assert.equal(r.headers.get('location'),jobPath(job));
 r=await get('/ajm-jobzone?job='+job.id);assert.equal(r.headers.get('location'),jobPath(job));
 r=await get('/jobs?search=chef&page=2');assert.equal(r.status,200);assert.equal(r.headers.get('x-robots-tag'),'noindex,follow');assert.deepEqual(calls.at(-1),{offset:25,search:'chef'});
 r=await get('/jobs?page=3');assert.equal(r.status,404);
 r=await get('/jobs/99999999-9999-4999-8999-999999999999/missing');assert.equal(r.status,404);assert(!(await r.text()).includes('"@type":"JobPosting"'));
 r=await get(jobPath(flyer));html=await r.text();assert(!html.includes('"@type":"JobPosting"'));assert(html.includes('Listing shown until'));assert(!html.includes('detail-application'));
 r=await get(jobPath(flyer)+'/flyer');assert.equal(r.status,200);assert.equal(r.headers.get('content-type'),'image/png');assert(requested[1][0].includes('/storage/v1/object/sign/jobzone-vacancy-flyers/'));assert(!requested[1][0].includes('127.0.0.1'));
 r=await get('/sitemap.xml');html=await r.text();assert(html.includes('/sitemaps/jobs-2.xml'));assert(!html.includes('usse-hub.com'));
 r=await get('/sitemaps/jobs-2.xml');html=await r.text();assert(html.includes(jobPath(flyer)));assert(!html.includes('<loc>https://ussehub.com/</loc>'));
 r=await get('/sitemaps/jobs-3.xml');assert.equal(r.status,404);
 for(const route of ['/server.mjs','/server/seo-core.mjs','/package.json','/supabase/migrations/test.sql','/tests/seo.test.mjs','/node_modules/serve/package.json']){r=await get(route);assert.equal(r.status,404,route);}
 r=await get('/admin-sw.js');assert.equal(r.status,200);assert.equal(r.headers.get('service-worker-allowed'),'/');
 r=await get('/ajm-jobzone-employer');assert.equal(r.headers.get('x-robots-tag'),'noindex,nofollow');
 const redirected=await new Promise((resolve,reject)=>{const request=http.get(origin+'/jobs',{headers:{host:'www.ussehub.com'}},response=>{response.resume();resolve(response);});request.on('error',reject);});assert.equal(redirected.headers.location,'https://ussehub.com/jobs');
 r=await get('/jobs',{method:'POST'});assert.equal(r.status,405);
 fail=true;r=await get('/jobs');assert.equal(r.status,503);assert.equal(r.headers.get('retry-after'),'60');r=await get('/');assert.equal(r.status,200);
 const publicClient=publicJobClient(async()=>new Response(JSON.stringify({rows:[{...job,applicant_name:'PRIVATE',owner_id:'PRIVATE'}, {...job,id:'bad'}, {...job,status:'closed'}],total:3}),{headers:{'content-type':'application/json'}}));const data=await publicClient.browse({offset:0});assert.equal(data.rows.length,1);assert.equal(data.rows[0].owner_id,undefined);assert.equal(data.rows[0].applicant_name,undefined);
 console.log('SEO tests passed: schema accuracy, escaping, crawlable routes, pagination, flyer isolation, sitemaps, outage handling and source protection.');
}finally{await new Promise(resolve=>server.close(resolve));}
