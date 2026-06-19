import pg from 'pg';
const { Client } = pg;
const client = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false }
});

const emails = process.argv.slice(2);
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
if (emails.length === 0) {
    console.error('Usage: node promote.mjs <email1> [email2 ...]');
    process.exit(1);
}

client.connect().then(() => {
    const emailList = emails.map(e => `'${e.replace(/'/g, "''")}'`).join(', ');
    return client.query(`
        UPDATE profiles SET role = 'admin', subscription_status = 'active' WHERE email IN (${emailList});
        SELECT email, role, subscription_status FROM profiles WHERE email IN (${emailList});
    `);
}).then(results => {
    const selectResult = Array.isArray(results) ? results[results.length - 1] : results;
    console.log('Updated rows found in profiles:', selectResult.rows.length);
    selectResult.rows.forEach(r => console.log(' -', r.email, '|', r.role, '|', r.subscription_status));
    return client.end();
}).catch(err => { console.error('Error:', err.message); client.end(); });
