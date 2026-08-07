# AYUR Flutter App

This app authenticates with Supabase Auth, not the legacy PHP/MySQL password
table.

## Admin Login Setup

If admin login fails, it is usually because no Supabase admin user exists yet.

1. In Supabase Dashboard, open Authentication -> Users.
2. Create a user (email + password), for example: admin@ayur.com.
3. Open SQL Editor and run the SQL in ../supabase/admin_bootstrap.sql to
	 promote that email to role = admin.
4. Sign in from the app with the same email/password you created in
	 Authentication -> Users.

Important:
- Credentials from old SQL dumps (for example admin@ayur.test / Ayur@1234)
	only work in the old MySQL flow and do not create a Supabase Auth user.
- If you changed role in SQL while already signed in, sign out and sign in
	again so role-based routing refreshes.

## Run (Web)

Example:

flutter run -d chrome --dart-define=AYUR_SUPABASE_URL=YOUR_URL --dart-define=AYUR_SUPABASE_ANON_KEY=YOUR_ANON_KEY
