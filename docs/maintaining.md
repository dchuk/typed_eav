---
title: "Maintainers"
---

# Maintaining and publishing the documentation

## Update docs with the API

Review documentation after every repository change, including code, tests, dependencies,
configuration, tooling, CI, migrations, and releases. Update affected pages in
the same change; if reader-facing behavior is unchanged, explain why no docs
update was needed in the handoff. Record user-visible changes in the root
`CHANGELOG.md` under Unreleased. A public API change includes its documentation
in the same change. Keep the
README focused on installation and discovery; maintain detailed usage here.

For each public capability, document a practical example, accepted inputs and
defaults, return value, and relevant failure behavior. Link its API reference to
its guide. Check claims against implementation and specs, especially transaction,
NULL, tenant, and callback behavior. A method being mentioned is not sufficient
coverage if users cannot work out how to call it.

Add new pages to the [documentation home](index.md) or the
[reference index](reference/index.md). Keep Markdown links relative between
published pages; `jekyll-relative-links` converts them to site URLs. Link to
GitHub for files outside `docs/`. Give new pages YAML front matter with a title
so Jekyll renders them. The sidebar automatically lists pages by `nav_group`
(assigned by folder defaults in `_config.yml`, or overridden in front matter).
Use `nav_exclude: true` for supporting pages that should be reachable only through
a summary page. Individual ADRs use this setting; their user-facing summary
appears once under Project. The active page is highlighted; mobile navigation uses an expandable menu.

The [changelog](changelog.md) is generated at build time from the root
`CHANGELOG.md` by `_plugins/changelog.rb`. Edit that source file only and rebuild
to preview changes. The workflow also runs when that file changes. Use ordinary Markdown headings and fenced examples.

## Preview locally

The documentation dependencies are isolated from the gem's development bundle.
From the gem repository:

```sh
cd docs
bundle install
bundle exec jekyll serve
```

Open `http://localhost:4000/typed_eav/`. The default layout uses the Minima theme;
there is no separate frontend application to maintain.

To build and check links from the repository root:

```sh
BUNDLE_GEMFILE=docs/Gemfile bundle exec jekyll build --source docs --destination docs/_site
python3 script/check_docs_site.py docs/_site /typed_eav
```

The checker verifies local page/asset targets and heading anchors in generated
HTML. It does not make network requests or certify the accuracy of examples.
Review examples against the relevant gem specs as part of each change.

After layout changes, check getting-started, field tables, and the API reference
at phone and desktop widths. Confirm the page itself does not scroll horizontally;
long code blocks and tables should scroll inside their own containers. Checking
only the documentation home misses content-dependent sizing bugs.

## Publish on GitHub Pages

The repository includes `.github/workflows/docs.yml`. Pull requests build and
check the site; pushes to `main` and manual runs on `main` also deploy it.

1. Commit and push the documentation and workflow to the gem repository.
2. In the repository's **Settings → Pages**, set **Source** to **GitHub Actions**.
3. Run the **Documentation** workflow on `main`, or push a documentation change.
4. Check the deployment URL in the workflow's `github-pages` environment.

The configured project URL is `https://dchuk.github.io/typed_eav/`. It becomes
available after the first successful deployment. For a different repository or
custom domain, update `url` and `baseurl` in `_config.yml` and the link-check
prefix in the workflow.

The site includes guides, references, and ADRs. Internal goal plans and
`improvement-program.md` are excluded, as are dependency and build files. Build
output is ignored by Git; GitHub Actions uploads the generated site directly.

See GitHub's [custom Pages workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
for repository permissions and deployment settings.
