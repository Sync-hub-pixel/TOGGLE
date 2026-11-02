# SYNC

SYNC is a single-user daily attendance app. Time In and Time Out are submitted
to a private Node.js API, which stores the timestamps in MongoDB Atlas. The
MongoDB credential stays on the server and is never embedded in Flutter.

## Rotate the exposed MongoDB password

The database URI previously shared in chat included a password. Rotate that
Atlas database user's password before connecting the app. Create a database
user with only `readWrite` access to the `sync` database. Do not put its URI
in Flutter, commit it, or send it in chat.

## Deploy the API on Render

The API is in `backend/` and requires Node.js 20 or later.

1. Push the contents of `demo_app/` to the root of the GitHub repository. The
   repository should contain `render.yaml`, `backend/`, and the Flutter files.
   The provided repository URL is currently empty, so this upload is required
   before Render can deploy it. Keep the repository private if you don't want
   the source code to be public.
2. In Render, choose **New** > **Blueprint**, connect
   `https://github.com/Sync-hub-pixel/TOGGLE`, and deploy the Blueprint from
   `render.yaml`. It creates a free Node web service using `backend/`,
   `npm ci`, and `npm start`; Render supplies HTTPS and the `PORT` value.
3. In the new service's **Environment** settings, set `MONGODB_URI` to the
   rotated Atlas URI. URL-encode special characters in the database user's
   password. Set `SYNC_USERNAME` to the username for your single app account.
   `MONGODB_DATABASE` is configured as `sync`, and Render generates the
   `JWT_SECRET`. Generate a bcrypt hash locally with `npm run hash-password`
   from `backend/`, then set it as `SYNC_PASSWORD_HASH`. Do not commit any of
   these secret values or put them in Flutter.
4. Configure a static outbound IP for the service if available, then allow that
   IP in Atlas **Network Access**. Do not allow every IP (`0.0.0.0/0`) for a
   deployed database. The Atlas database user should have only `readWrite`
   access to the `sync` database.
5. After Render deploys, copy its HTTPS service URL for the Flutter app.
6. The service creates a unique index and an `attendance` collection when it
   starts. A record is stored once per account and local date; repeated punches
   are rejected by the API. The authenticated history endpoint returns at most
   the latest 100 records.

Generate a random JWT secret locally without sharing it:

```powershell
node -e "console.log(require('node:crypto').randomBytes(48).toString('base64url'))"
```

Do not commit a `.env` file. `backend/.env.example` lists the variable names;
`backend/.gitignore` excludes private environment files.

## Run the Flutter app

Build against your deployed HTTPS API URL:

```powershell
flutter pub get
flutter run -d emulator-5554 --dart-define=SYNC_API_BASE_URL=https://your-api-host.example.com
```

Replace the example URL with the HTTPS URL given by your host. Sign in with
the password used to create `SYNC_PASSWORD_HASH`; `SYNC_USERNAME` identifies
the single account on the server, so the app does not ask for a username.
The app opens directly on the Toggle screen. The Storage tab asks for the API
password before loading attendance history, and the first punch also asks for
the password if no valid session is stored. The app securely stores its
short-lived session token. Each punch is saved to MongoDB, and today's record
is loaded again when the app opens.

## Check the API

```powershell
cd backend
npm install
npm test
```
