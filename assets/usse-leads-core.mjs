export const LEAD_STAGES=['new','contacted','qualified','won','lost','spam'];
export const LEAD_SOURCES=['website','email','whatsapp','subscription','phone','walk_in','other'];
export const isEmail=v=>typeof v==='string'&&v.length<=254&&/^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}$/i.test(v);
export const escapeHtml=v=>String(v??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
export function contactLinks(lead){
 const raw=String(lead.phone||'').trim(),digits=raw.replace(/\D/g,'');let wa=digits;
 if(digits.length===7)wa='1876'+digits;else if(digits.length===10&&digits.startsWith('876'))wa='1'+digits;
 const links={};if(isEmail(lead.email))links.email=`mailto:${encodeURIComponent(lead.email)}?subject=${encodeURIComponent('Re: '+(lead.service||'Your USSE enquiry')+' — '+(lead.lead_reference||''))}`;
 if(/^[+\d\s().-]+$/.test(raw)&&digits.length>=7&&digits.length<=15)links.phone='tel:'+(raw.startsWith('+')||wa!==digits?'+':'')+(wa!==digits?wa:digits);
 if(wa.length>=11&&wa.length<=15)links.whatsapp=`https://wa.me/${wa}?text=${encodeURIComponent(`Hello ${lead.customer_name||''}, thank you for contacting USSE${lead.service?' about '+lead.service:''}. I’m following up on your enquiry (${lead.lead_reference||''}).`)}`;
 return links;
}
const vc=v=>String(v??'').replaceAll('\\','\\\\').replace(/\r\n|\r|\n/g,'\\n').replaceAll(';','\\;').replaceAll(',','\\,');
export function leadVCard(lead){
 return ['BEGIN:VCARD','VERSION:3.0','FN:'+vc(lead.customer_name),'N:;'+vc(lead.customer_name)+';;;',...(lead.company?['ORG:'+vc(lead.company)]:[]),...(lead.email?['EMAIL;TYPE=INTERNET:'+vc(lead.email)]:[]),...(lead.phone?['TEL;TYPE=CELL:'+vc(lead.phone)]:[]),'NOTE:'+vc(`${lead.lead_reference||''} | ${lead.branch||'USSE'} | ${lead.service||''}\n${lead.notes||''}`),'END:VCARD',''].join('\r\n');
}
export function csvCell(value){const s=String(value??'');return '"'+(/^[\s]*[=+@\-\t\r]/.test(s)?"'"+s:s).replaceAll('"','""')+'"';}
export function leadsCSV(rows){
 const fields=[['Reference','lead_reference'],['Received (UTC)','created_at'],['Name','customer_name'],['Company','company'],['Phone','phone'],['Email','email'],['Channel','source'],['Branch','branch'],['Service','service'],['Source page','source_page'],['Business listing','listing_name'],['Listing ID','listing_id'],['Capture origin','capture_origin'],['Campaign source','utm_source'],['Campaign','utm_campaign'],['Referring website','referrer_host'],['Stage','lead_stage'],['Priority','priority'],['Assigned admin ID','assigned_to'],['Follow-up (UTC)','follow_up_at'],['Enquiry','notes']];
 return '\ufeff'+[fields.map(([label])=>csvCell(label)).join(','),...rows.map(row=>fields.map(([,key])=>csvCell(row[key]??row.attribution?.[key])).join(','))].join('\r\n');
}
export function normalizeLead(input){
 const text=(key,max)=>{const v=String(input[key]??'').trim();if(v.length>max)throw new Error(`${key.replaceAll('_',' ')} is too long.`);return v;};
 const data={customer_name:text('customer_name',100),phone:text('phone',50),email:text('email',254).toLowerCase(),notes:text('notes',4000),company:text('company',150),service:text('service',150),branch:text('branch',80)||'USSE',source:text('source',30)||'website',listing_id:input.listing_id||null,consent:input.consent===true,attribution:{}};
 if(data.customer_name.length<2||data.notes.length<5)throw new Error('Enter your name and an enquiry of at least 5 characters.');
 if(!data.phone&&!data.email)throw new Error('Provide a phone number or email address.');
 if(data.email&&!isEmail(data.email))throw new Error('Enter a valid email address.');
 if(data.phone&&(!/^[+\d\s().-]+$/.test(data.phone)||data.phone.replace(/\D/g,'').length<7||data.phone.replace(/\D/g,'').length>15))throw new Error('Enter a valid phone number, including the country code where possible.');
 if(!['email','whatsapp','website','subscription','phone'].includes(data.source))throw new Error('Invalid contact channel.');
 if(!data.consent)throw new Error('Please agree to be contacted about this enquiry.');
 if(data.listing_id&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(data.listing_id))throw new Error('Invalid business listing.');
 if(!['USSE','USSE Consultancy','AJM','PISTOL'].includes(data.branch))data.branch='USSE';
 try{const u=new URL(input.source_page||'https://ussehub.com/','https://ussehub.com');data.source_page=u.hostname==='ussehub.com'?u.pathname.slice(0,200):'/';}catch{data.source_page='/';}
 for(const key of ['utm_source','utm_medium','utm_campaign','utm_content','utm_term','referrer_host'])if(typeof input.attribution?.[key]==='string')data.attribution[key]=input.attribution[key].slice(0,160);
 return data;
}
