# Trackboard

Trackboard is a shared recording-progress board for bands. Projects, songs, instruments, and completed parts are stored in Supabase; signed-in project members see changes live.

## Run locally

1. Create a Supabase project.
2. In the Supabase SQL Editor, run the migrations in order: [`202611160001_trackboard.sql`](./supabase/migrations/202611160001_trackboard.sql), [`202611160002_optional_song_parts.sql`](./supabase/migrations/202611160002_optional_song_parts.sql), and [`202611160003_reorder_instruments.sql`](./supabase/migrations/202611160003_reorder_instruments.sql).
3. In Supabase Authentication settings, enable email/password sign-in, set the site URL, and add your local URL (for example `http://localhost:5173/**`) to the allowed redirect URLs.
4. Copy `.env.example` to `.env` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` using the project URL and publishable/anon key from Supabase API settings. Never put a service-role key in the browser app.
5. Run `npm install`, then `npm run dev`.

The app requires a Supabase project; it does not silently fall back to device-only storage when the backend is unavailable.

## Deploy to GitHub Pages

1. Push this project to a GitHub repository using the `main` branch.
2. In the repository settings, add Actions secrets named `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. Use the Supabase project URL and publishable/anon key; never use the service-role key.
3. Under **Settings → Pages**, set the source to **GitHub Actions**.
4. In Supabase Authentication settings, set the site URL to `https://YOUR-USERNAME.github.io/YOUR-REPOSITORY/` and add that URL with `**` to the allowed redirect URLs.
5. Push to `main` or run **Deploy Trackboard to GitHub Pages** from the repository's Actions tab. The workflow builds and publishes the site.

The GitHub Actions workflow uses a relative Vite asset base, so it works for GitHub project pages hosted below `/<repository>/`.

## Sharing and access

Create an account or sign in with email and password. Create a project, then use **Share board** to create a reusable invite link that expires after 30 days. The recipient signs in or creates an account before joining. Anyone who has the invite link can join, so share it only with bandmates. Project members can edit songs, instruments, and progress; project owners can rename and delete projects.

Supabase Row Level Security policies restrict reads and writes to project members. Members can track parts and add songs or instruments; only the project owner can rename/delete the project or remove existing songs and instruments. Invite tokens are only returned by the membership-checked invite RPC, and invite acceptance is performed by a database function after authentication. Configure your production site's URL and authentication redirect allow-list in Supabase before deployment.

## Existing local boards

On the first sign-in to an account with no projects, a board saved by the earlier browser-only version is imported from that browser's local storage (`trackboard-board-v1` or `roomtone-board-v1`). The original local copy is retained as a backup.
