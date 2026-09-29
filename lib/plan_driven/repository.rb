# frozen_string_literal: true

require "open3"

module PlanDriven
  # The GitHub repository the application lives in, from config or the `origin` remote.
  module Repository
    # Also matches SSH host aliases such as git@github.com-work:acme/app.git.
    REMOTE = %r{github\.com(?:-[\w.-]+)?[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?\z}

    module_function

    def slug(config = PlanDriven.configuration)
      config.github_repository.presence || from_remote(config.root_path)
    end

    def from_remote(root)
      output, status = Open3.capture2("git", "-C", root.to_s, "remote", "get-url", "origin", err: File::NULL)
      return unless status.success?

      parse(output.strip)
    rescue StandardError
      nil
    end

    def parse(url)
      url.to_s.strip[REMOTE, 1]
    end

    def head_sha(root = PlanDriven.configuration.root_path)
      output, status = Open3.capture2("git", "-C", root.to_s, "rev-parse", "HEAD", err: File::NULL)
      status.success? ? output.strip : nil
    end
  end
end
