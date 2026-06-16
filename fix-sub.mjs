import pg from 'pg';
const { Client } = pg;
const DB_URL = process.env.DATABASE_URL;
async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    await client.connect();
    await client.query("UPDATE profiles SET subscription_status = 'inactive' WHERE subscription_status = 'active';");
    console.log("Fixed subscription_status");
    await client.end();
}
main();
