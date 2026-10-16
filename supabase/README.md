# STARLIGHT ACADEMY — Supabase setup

The website uses GitHub Pages for the front end and Supabase for shared records and authentication.

## 1. Create the database schema

1. Open the project's Supabase Dashboard.
2. Open **SQL Editor** and create a new query.
3. Open this repository's `supabase/setup.sql`, copy the entire file, paste it into SQL Editor, and run it once.
4. Confirm the query completes without an error before continuing.

This creates the shared records table, account profile table, access rules, authentication trigger, and server-validated RPCs. The browser publishable key is used by the front end; do not put a secret/service-role key into the website.

## 2. Configure email/password sign-in

The legacy site uses usernames instead of email addresses. The front end maps a username to a synthetic address ending in `@starlight.invalid` for Supabase Auth.

In Supabase, open **Authentication → Sign-in / Providers → Email** and disable email confirmation for this username-based setup. Users still sign in with their username and password on the website; they do not need to enter the synthetic address.

## 3. Migrate the existing website data

**Do this on the browser/device that currently has the real site data in its local storage. Do not clear that browser's site data.**

1. Open the published STARLIGHT ACADEMY site in that browser.
2. Sign in with the existing site admin's username and password. The site checks the legacy local password hash and creates the matching Supabase Auth account on first sign-in.
3. The first account's Supabase profile starts with the `player` role by design. In SQL Editor, promote the existing admin account, replacing `Admin` if the username is different:

   ```sql
   update public.site_profiles
   set role = 'admin'
   where lower(username) = lower('Admin');
   ```

4. Reload the website in that same browser. The site now detects the admin profile and imports the local snapshot only when the shared table is empty. The import excludes local password hashes.
5. Open the site on the other device, sign in with the same username/password, and confirm the same characters, threads, posts, and balances appear.

The import is intentionally blocked if cloud records already exist to prevent accidentally overwriting shared data. Keep a backup of the original local data until the first migration has been confirmed.

## 4. Important notes

- The anon/publishable key is intended for front-end use; database authorization is enforced by row-level security and server-side functions.
- Never put a Supabase `service_role` or `sb_secret_...` key in this repository.
- Existing users should first sign in from a browser where their legacy password is available, so their Supabase Auth account can be created. After that, they can sign in on other devices normally.
- Password hashes from local storage are not imported into the shared records table.
- If SQL Editor reports an error, stop and fix that error before trying to register or migrate accounts.
