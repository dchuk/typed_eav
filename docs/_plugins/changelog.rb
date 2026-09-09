# frozen_string_literal: true

# Render the repository's canonical changelog without maintaining a second copy.
module TypedEAVDocs
  class Changelog < Jekyll::Generator
    safe true
    priority :high

    def generate(site)
      page = Jekyll::PageWithoutAFile.new(site, site.source, "", "changelog.md")
      page.content = File.read(File.expand_path("../CHANGELOG.md", site.source))
      # The source changelog resolves links from the repository root; this page
      # lives at the documentation root instead.
      page.content = page.content.gsub("](docs/", "](")
      page.data.merge!("title" => "Changelog", "layout" => "documentation", "nav_group" => "Project")
      site.pages << page
    end
  end
end
