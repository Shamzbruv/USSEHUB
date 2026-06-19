import { createClient } from '@supabase/supabase-js';
import ws from 'ws';
globalThis.WebSocket = ws;

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://zcptuqrlovflcpqszery.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

async function runTests() {
  console.log('Testing RLS rules from anonymous client...');
  let failed = false;
  
  // Test: Should not be able to read all profiles
  const { data: profiles, error: profileErr } = await supabase.from('profiles').select('*');
  if (profileErr) {
    console.log('✅ Profiles read blocked as expected.');
  } else if (profiles && profiles.length > 0) {
    console.error('❌ Security risk: Profiles are publicly readable!');
    failed = true;
  }

  // Test: Should only see active ad packages
  const { data: packages, error: packageErr } = await supabase.from('ad_packages').select('*');
  if (packageErr) {
    console.error('❌ Error reading ad_packages:', packageErr.message);
    failed = true;
  } else {
    const inactive = packages.filter(p => !p.is_active);
    if (inactive.length > 0) {
      console.error('❌ Security risk: Inactive packages are publicly visible!');
      failed = true;
    } else {
      console.log('✅ Only active ad_packages are publicly visible.');
    }
  }

  // Test: Should not be able to read consultations
  const { data: consultations, error: consultErr } = await supabase.from('consultations').select('*');
  if (consultErr) {
    console.log('✅ Consultations read blocked as expected.');
  } else if (consultations && consultations.length > 0) {
    console.error('❌ Security risk: Consultations are publicly readable!');
    failed = true;
  }

  // Test: Should not be able to insert listing without being logged in
  const { error: insertErr } = await supabase.from('listings').insert([
    { business_name: 'Hacked', location: 'kingston', category: 'SERVICES', status: 'approved' }
  ]);
  if (insertErr) {
    console.log('✅ Anonymous listing insert blocked as expected.');
  } else {
    console.error('❌ Security risk: Anonymous users can insert listings!');
    failed = true;
  }

  console.log('RLS tests complete.');
  
  console.log('Testing authenticated RLS rules...');
  const testEmail = `test_${Date.now()}@example.com`;
  const { data: authData, error: authErr } = await supabase.auth.signUp({
    email: testEmail,
    password: 'TestPassword123!'
  });

  if (authErr) {
    console.warn('⚠️ Could not sign up test user. Make sure Email Auth is enabled and allows signups.');
    console.warn('Auth Error:', authErr.message);
  } else if (authData.user) {
    const userId = authData.user.id;
    
    // Test: Authenticated user cannot insert an approved listing
    const { error: insertApprovedErr } = await supabase.from('listings').insert([
      { business_name: 'Auth Hacked', location: 'kingston', category: 'SERVICES', status: 'approved', owner_user_id: userId }
    ]);
    if (insertApprovedErr) {
      console.log('✅ Authenticated insert of approved listing blocked as expected.');
    } else {
      console.error('❌ Security risk: Authenticated users can insert approved listings!');
      failed = true;
    }

    // Test: Authenticated user cannot insert a featured listing
    const { error: insertFeaturedErr } = await supabase.from('listings').insert([
      { business_name: 'Auth Hacked 2', location: 'kingston', category: 'SERVICES', status: 'pending', is_featured: true, owner_user_id: userId }
    ]);
    if (insertFeaturedErr) {
      console.log('✅ Authenticated insert of featured listing blocked as expected.');
    } else {
      console.error('❌ Security risk: Authenticated users can insert featured listings!');
      failed = true;
    }
  }

  if (failed) {
    process.exit(1);
  }
}

runTests();
