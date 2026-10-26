<!-- Add this section to the app repo's CLAUDE.md (create the file if there isn't one). -->
## Hosting

This app is hosted on the Virtuals internal app platform (Google Cloud Run, through
Virtual-Protocol/projects-autodeploy) and deploys automatically when `main` changes. For
anything that touches hosting, settings and secrets, the database, files, sign-in, background
work, the Dockerfile or GitHub Actions, follow the `virtuals-platform:internal-app` skill, and
run its checker before saying the app is ready.
