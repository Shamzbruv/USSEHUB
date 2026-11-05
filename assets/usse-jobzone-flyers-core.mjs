export const FLYER_BUCKET='jobzone-vacancy-flyers';
export const FLYER_LIMIT=5*1024*1024;
export function flyerUrl(value){try{const u=new URL(value);return u.protocol==='https:'&&!u.username&&!u.password?u.href:'';}catch{return '';}}
export async function validateFlyer(file){
 if(!file||!file.size||file.size>FLYER_LIMIT)throw new Error('Choose a vacancy image up to 5 MB.');
 const bytes=new Uint8Array(await file.slice(0,12).arrayBuffer());
 const ascii=(start,end)=>String.fromCharCode(...bytes.slice(start,end));
 const format=bytes[0]===137&&ascii(1,4)==='PNG'&&bytes[4]===13&&bytes[5]===10&&bytes[6]===26&&bytes[7]===10?{mime:'image/png',extension:'png'}:bytes[0]===255&&bytes[1]===216&&bytes[2]===255?{mime:'image/jpeg',extension:'jpg'}:ascii(0,4)==='RIFF'&&ascii(8,12)==='WEBP'?{mime:'image/webp',extension:'webp'}:null;
 if(!format||file.type&&!['image/jpeg','image/png','image/webp'].includes(file.type))throw new Error('Use a JPG, PNG or WebP picture of the vacancy flyer.');
 return {...format,size:file.size};
}
export function sharedVacancyLink(origin,id){return new URL('/jobs/'+encodeURIComponent(id),origin).href;}
export function flyerImageMarkup(job,escape,{detail=false}={}){return job.flyer_url?`<a class="job-flyer-image ${detail?'job-flyer-image--full':''}" href="${escape(job.flyer_url)}" target="_blank" rel="noopener noreferrer" aria-label="Open vacancy flyer for ${escape(job.title)}"><img data-flyer-image="${escape(job.id)}" src="${escape(job.flyer_url)}" alt="Vacancy flyer: ${escape(job.title)} at ${escape(job.company_name)}. Open the image to read the full advert." loading="lazy"></a>`:job.post_kind==='flyer'?'<p class="market-note">The flyer preview is unavailable. Refresh this page to try again, or use the advertiser’s details below.</p>':'';}
