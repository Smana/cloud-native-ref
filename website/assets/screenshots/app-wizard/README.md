# App Wizard screenshots

**Not yet captured.** This directory holds no images, and
[App Wizard](../../../content/docs/platform/developer-platform/app-wizard.md)
embeds none — the page describes the wizard in prose only. (An earlier version
of this file claimed the five PNGs below "are referenced by `app-wizard.md`";
they were not, and the page had no image references at all.)

To fill the gap, capture from the running wizard
(`https://app-wizard.priv.cloud.ogenki.io`, or a local `npm run dev` /
container run), drop the PNGs here, and add the embeds to the page. Suggested
width ~1400px, light theme, matching the ogenki branding.

| File | What it should show |
|------|---------------------|
| `01-create-form.png` | Landing / create form: basic tier (name, stack, image, route) on the left, live YAML pane on the right |
| `02-advanced.png` | An expanded advanced section (e.g. `sqlInstance` + `autoscaling`) |
| `03-validation.png` | An inline validation error (e.g. "route.hostname is required when route is enabled") |
| `04-render-preview.png` | The render-preview panel listing rendered resource kinds/names |
| `05-pull-request.png` | The resulting GitHub PR (or the success state with the PR link + render comment) |

`website/assets/` is Hugo's asset pipeline, reachable from a template through
`resources.Get`. Images embedded directly from Markdown with a site-root path
belong in `website/static/` instead — see the note at the top of
`scripts/export-diagrams.sh`, which records the same distinction for diagrams.
