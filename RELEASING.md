# Releasing typed_eav

A release is complete only when the same stable version exists in all three
places:

1. `lib/typed_eav/version.rb` and `CHANGELOG.md`
2. RubyGems
3. a published GitHub Release for the exact `vVERSION` tag

The newest stable GitHub Release must also be marked **Latest**. A successful
gem push by itself is not a completed release.

## Prepare the release

1. Confirm `main` is clean and up to date.
2. Move the relevant notes from `[Unreleased]` into a dated
   `## [VERSION] - YYYY-MM-DD` section in `CHANGELOG.md`.
3. Add the matching link definition at the bottom of `CHANGELOG.md`:

   ```markdown
   [VERSION]: https://github.com/dchuk/typed_eav/releases/tag/vVERSION
   ```

4. Set `TypedEAV::VERSION` in `lib/typed_eav/version.rb`.
5. Run the full release verification locally:

   ```sh
   bundle exec rspec
   bundle exec rubocop
   gem build typed_eav.gemspec
   ```

6. Commit the release preparation using the repository commit convention.

## Publish

Create and push an annotated `vVERSION` tag that points at the release commit.
The `Release` GitHub Actions workflow then:

1. verifies the exact tagged source and compatibility matrix;
2. builds and tests one checksummed gem artifact;
3. publishes that artifact to RubyGems using trusted publishing; and
4. creates or verifies the stable GitHub Release and marks it **Latest**.

Do not manually publish the gem ahead of this workflow. Do not declare the
release complete until both the `Push verified gem to RubyGems` and
`Publish GitHub release` jobs succeed.

## Verify completion

Replace `VERSION` below, then verify all release surfaces:

```sh
test "$(ruby -r ./lib/typed_eav/version -e 'print TypedEAV::VERSION')" = "VERSION"
test "$(curl -fsSL https://rubygems.org/api/v1/gems/typed_eav.json | jq -r .version)" = "VERSION"
gh release view "vVERSION" --json tagName,isDraft,isPrerelease,url
gh release list --limit 10
```

The GitHub release must use tag `vVERSION`, with `isDraft: false` and
`isPrerelease: false`, and the release list must label it `Latest`.

## Recover a missing GitHub Release

If RubyGems publishing succeeds but the final GitHub job fails, rerun the
failed `Publish GitHub release` job. The job is idempotent: it creates a
missing release or verifies an existing stable release and restores its
**Latest** designation.

If automation is unavailable, use:

```sh
gh release create "vVERSION" \
  --verify-tag \
  --title "typed_eav VERSION" \
  --generate-notes \
  --latest
```

Then repeat the completion checks above. Never create, move, or replace a tag
just to repair missing GitHub release metadata.
