import { createClient } from '@supabase/supabase-js';
import ws from 'ws';
globalThis.WebSocket = ws;

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://zcptuqrlovflcpqszery.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

async function runTests() {
  console.log('Testing RLS rules from anonymous client...');
  
  // Test: Should not be able to read all profiles
  const { data: profiles, error: profileErr } = await supabase.from('profiles').select('*');
  if (profileErr) {
    console.log('✅ Profiles read blocked as expected.');
  } else if (profiles && profiles.length > 0) {
    console.error('❌ Security risk: Profiles are publicly readable!');
  }

  // Test: Should only see active ad packages
  const { data: packages, error: packageErr } = await supabase.from('ad_packages').select('*');
  if (packageErr) {
    console.error('❌ Error reading ad_packages:', packageErr.message);
  } else {
    const inactive = packages.filter(p => !p.is_active);
    if (inactive.length > 0) {
      console.error('❌ Security risk: Inactive packages are publicly visible!');
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
  }

  console.log('RLS tests complete.');
}

runTests();
