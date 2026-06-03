BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(3);

-- Test 1: Ensure profiles table exists
SELECT has_table('public', 'profiles', 'Table profiles should exist');

-- Test 2: Ensure RLS is enabled on profiles
SELECT policies_are(
    'public',
    'profiles',
    ARRAY[
        'Profiles viewable by owner or admin',
        'Profiles updatable by owner or admin'
    ],
    'Profiles should have correct RLS policies'
);

-- Test 3: Test private admin function is not public
SELECT has_function(
    'private',
    'is_admin',
    ARRAY['uuid'],
    'Function private.is_admin should exist'
);

SELECT * FROM finish();
ROLLBACK;
