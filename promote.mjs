import pg from 'pg';
const {Client} = pg;
const emails = [...new Set(process.argv.slice(2).map(email => email.trim().toLowerCase()))];
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
if (!emails.length || emails.some(email => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) throw new Error('Usage: node promote.mjs <email> [email ...]');
const client = new Client({connectionString:process.env.DATABASE_URL,ssl:{rejectUnauthorized:false}});
try {
  await client.connect(); await client.query('BEGIN');
  await client.query('INSERT INTO private.admin_email_grants(email) SELECT unnest($1::text[]) ON CONFLICT(email) DO NOTHING',[emails]);
  await client.query('SELECT private.apply_reserved_admin(id) FROM auth.users WHERE lower(email)=ANY($1::text[]) AND email_confirmed_at IS NOT NULL',[emails]);
  const {rows} = await client.query(`SELECT g.email,g.claimed_user_id IS NOT NULL AS activated,p.role FROM private.admin_email_grants g LEFT JOIN public.profiles p ON p.id=g.claimed_user_id WHERE g.email=ANY($1::text[])`,[emails]);
  await client.query('COMMIT');
  for (const row of rows) console.log(row.email, row.activated ? `activated (${row.role})` : 'reserved; waiting for verified signup');
} catch (error) {
  await client.query('ROLLBACK').catch(()=>{}); console.error('Administrator reservation failed:',error.message); process.exitCode=1;
} finally { await client.end(); }
