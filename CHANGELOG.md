# Changelog

The project version lives in `VERSION` and is shown in the dashboard's About
panel (click the logo). Versions before 0.10.0 were not numbered; 0.10.0 is
the tenth merged change since the `v0.1.0-pre` tag.

The number updates by itself: every change merged to `main` gets the next
patch number from `.github/workflows/bump-version.yml`, which also adds the
change to this file. A pull request that edits `VERSION` itself (for a bigger
jump) is left as it is.

## 0.10.0 - 2026-10-09
- Dashboard: the About panel shows the installed project version. The
  installer writes it next to the page and the nightly routine keeps it in
  step with the checkout it was installed from.
- Includes everything merged up to PR #9: free AI tier and prices in pounds,
  fixes for repeating nightly warnings, click a healthy container to see its
  installed version.
