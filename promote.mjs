import pg from 'pg';
const { Client } = pg;
const client = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false }
});
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
client.connect().then(() => {
    return client.query(`
        UPDATE profiles SET role = 'admin', subscription_status = 'active' WHERE email = 'Shamzbiz1@gmail.com';
        UPDATE profiles SET role = 'admin', subscription_status = 'active' WHERE email = 'usseja2k@gmail.com';
        SELECT email, role, subscription_status FROM profiles WHERE email IN ('Shamzbiz1@gmail.com', 'usseja2k@gmail.com');
    `);
}).then(results => {
    const selectResult = Array.isArray(results) ? results[results.length - 1] : results;
    console.log('Updated rows found in profiles:', selectResult.rows.length);
    selectResult.rows.forEach(r => console.log(' -', r.email, '|', r.role, '|', r.subscription_status));
    return client.end();
}).catch(err => { console.error('Error:', err.message); client.end(); });
