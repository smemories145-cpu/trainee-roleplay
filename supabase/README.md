# STARLIGHT ACADEMY — Supabase setup

The website uses GitHub Pages for the front end and Supabase for shared records and authentication.

## 1. Create the database schema

1. Open the project's Supabase Dashboard.
2. Open **SQL Editor** and create a new query.
3. Open this repository's `supabase/setup.sql`, copy the entire file, paste it into SQL Editor, and run it once.
4. Confirm the query completes without an error before continuing.

This creates the shared records table, account profile table, access rules, authentication trigger, and server-validated RPCs. The browser publishable key is used by the front end; do not put a secret/service-role key into the website.

## Disable the legacy cash-transfer path

The old profile-page transfer control and `site_transfer` RPC have been removed. Character cash balances remain unchanged, but characters can no longer transfer cash directly to each other through the legacy path.

For an existing Supabase project, open **Supabase Dashboard → SQL Editor**, then run the complete `supabase/remove-legacy-cash-transfer.sql` file from this repository. This drops the old RPC from the live database and refreshes the PostgREST schema cache. Updating GitHub files alone cannot remove a function that is already installed in Supabase.

New inter-character transfers must be implemented through the bank-account system only. Do not restore or re-grant `site_transfer`.

## Fix: character biography thread RPC not found

If posting a character archive shows `Could not find the function public.site_create_character_bio_thread(p_thread) in the schema cache`, or after you deploy new custom-HTML archive mode, apply the latest RPC migration below.

1. Open **Supabase Dashboard → SQL Editor** for the same project connected to STARLIGHT ACADEMY.
2. Open `supabase/character_bio_threads.sql` from this repository, copy the entire file, paste it into SQL Editor, and run it. You can safely run this migration again; it uses `CREATE OR REPLACE`.
3. Wait for the query to finish successfully, then reload STARLIGHT ACADEMY with **Ctrl + F5** and try creating/editing a biography thread again.

The latest migration keeps both `rich` and `html` biography display modes, updates the create/edit RPCs, restores their authenticated permissions, and sends a PostgREST schema-cache refresh notification. The `html` mode is displayed in a sandboxed iframe so a player's own CSS does not style the main website. The website repository cannot change database functions in your Supabase project by itself, so this SQL step must be run in the connected Supabase project.

## 2. Configure email/password sign-in

The legacy site uses usernames instead of email addresses. The front end maps a username to a synthetic address ending in `@starlight.invalid` for Supabase Auth.

In Supabase, open **Authentication → Sign-in / Providers → Email** and disable email confirmation for this username-based setup. Users still sign in with their username and password on the website; they do not need to enter the synthetic address.

## 3. Bootstrap the first administrator

You do **not** need an existing admin ID. The project owner promotes the first account from SQL Editor.

1. Use the browser/device that contains the original site's real data. **Do not clear its local storage.**
2. On the website, register a Cloud account or sign in with an existing legacy admin account if you still have its credentials.
3. If the cloud database is empty and there is no admin yet, the site displays a **Set up first admin** screen with a SQL command for the account you just authenticated. Copy it into Supabase SQL Editor and run it.
4. Return to the website and reload. The signed-in account should now be recognized as admin, and the site imports the existing local snapshot only when the shared table is empty. Local password hashes are not imported.
5. Keep a backup of the original local data until the migration is confirmed.

The first-admin SQL command is guarded so it only works while there is no admin and no cloud records. Do not promote accounts through public front-end code.

## 4. Sign in on other devices

Once the first admin has been established and the original data has migrated, open the website on the other device and register/sign in with the appropriate account. Legacy users who have not yet created a Supabase Auth identity need to sign in once on the browser where their legacy password is stored, or create a new Cloud account. Confirm the same characters, threads, posts, and balances appear before removing any old local data.

The import is intentionally blocked if cloud records already exist to prevent accidentally overwriting shared data.

## 4. Important notes

- The anon/publishable key is intended for front-end use; database authorization is enforced by row-level security and server-side functions.
- Never put a Supabase `service_role` or `sb_secret_...` key in this repository.
- Existing users should first sign in from a browser where their legacy password is available, so their Supabase Auth account can be created. After that, they can sign in on other devices normally.
- Password hashes from local storage are not imported into the shared records table.
- If SQL Editor reports an error, stop and fix that error before trying to register or migrate accounts.


## Phone and bank system (existing installations)

The phone screen and bank RPCs are in the front end and the `site_bank_*` database functions. For an existing Supabase project, run `supabase/banking-phone-migration.sql` once in **Supabase Dashboard → SQL Editor**. This migration is safe to re-run: it creates missing banking tables/functions and leaves existing character cash and other site records intact.

- Each approved character can open one account immediately; opening is free and starts at ₩0.
- Cash balances stay in `characters.won`; bank balances are stored separately.
- Deposit, withdrawal and transfer are server-side, transactional RPCs with a unique request ID and a transaction log. Transfer is bank-account-to-bank-account only.
- Fees start at 0% and can be configured by an administrator with `manage_economy` permission (or site admin) from the bank administration page.
- The migration does not create private chat, group chat, item transfer or notifications yet; those app tiles are a phone shell for subsequent implementation.
- Do not add a Supabase service-role key to the public website.



## Phone messaging and remaining apps

The floating phone button and app views are included in `index.html`. For existing Supabase installations, run the following files in order from **Supabase Dashboard → SQL Editor**:

1. `supabase/banking-phone-migration.sql` (if it has not already been installed).
2. `supabase/phone-messaging-migration.sql`.

Use the complete current file from GitHub (open it, choose **Raw**, then copy all), not a previously copied SQL query. Do not rerun `setup.sql` on an existing production database.

The phone migration adds private and group conversations, group invitations and ownership controls, read receipts, message hiding/unsend/reporting, character-level contacts and blocks, online/last-seen privacy, notifications, item transfer with history, email thread IDs, and phone-administration RPCs. It also sends phone notification metadata when bank transactions or private mail arrive. Admins can inspect message bodies only from submitted reports.

The item editor now includes a **transferable** setting; existing items default to transferable unless explicitly set to false. Transactions are performed through validated RPCs; direct table access remains revoked. GitHub Pages deployment does not execute SQL against your Supabase project, so the migrations must be run there once.
