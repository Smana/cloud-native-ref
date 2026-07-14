# App Wizard screenshots

Drop the following PNGs here; they are referenced by [`docs/app-wizard.md`](../../app-wizard.md).
Capture from the running wizard (`https://app-wizard.priv.cloud.ogenki.io`, or a
local `npm run dev` / container run).

| File | What it should show |
|------|---------------------|
| `01-create-form.png` | Landing / create form: basic tier (name, stack, image, route) on the left, live YAML pane on the right |
| `02-advanced.png` | An expanded advanced section (e.g. `sqlInstance` + `autoscaling`) |
| `03-validation.png` | An inline validation error (e.g. "route.hostname is required when route is enabled") |
| `04-render-preview.png` | The render-preview panel listing rendered resource kinds/names |
| `05-pull-request.png` | The resulting GitHub PR (or the success state with the PR link + render comment) |

Suggested width ~1400px, light theme (matches the ogenki branding).
