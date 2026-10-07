# Azure Local, Discovery to Day 2: follow-along site

The static site for this session's follow-along pages. The content is `src/content.json`, generated from the session's demo guide and limited to what attendees need: goals, prerequisites, steps, expected results, troubleshooting, clean-up and repository paths. The GitHub Pages workflow in `.github/workflows/pages.yml` builds it and publishes it at `https://thisismydemo.github.io/nic2026_azl/`.

Build it locally:

```powershell
npm ci
$env:SITE_BASE = '/nic2026_azl/'
npm run build
npm run preview
```

Without `SITE_BASE` the build uses relative paths, so the `dist` folder also opens from a plain folder.
