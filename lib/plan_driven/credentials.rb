# frozen_string_literal: true

require "yaml"
require "fileutils"
require "open3"

module PlanDriven
  # Keys live outside the application, in ~/.plan_driven/config (0600 inside a 0700 directory):
  #
  #     openai_api_key: sk-...
  #     anthropic_api_key: sk-ant-...
  #     cursor_api_key: key_...
  #     github_token: ghp_...
  #
  # The environment always wins, and a key found there is never copied into the file.
  module Credentials
    KEYS = {
      "openai_api_key" => "OPENAI_API_KEY",
      "anthropic_api_key" => "ANTHROPIC_API_KEY",
      "cursor_api_key" => "CURSOR_API_KEY",
      "github_token" => "GITHUB_TOKEN"
    }.freeze

    DIRECTORY = File.join(Dir.home, ".plan_driven")

    class << self
      def path
        ENV.fetch("PLAN_DRIVEN_CREDENTIALS", File.join(DIRECTORY, "config"))
      end

      def fetch(name)
        name = name.to_s
        env = KEYS.fetch(name)
        value = ENV[env].to_s.strip
        return value unless value.empty?

        stored = read[name].to_s.strip
        return stored unless stored.empty?

        name == "github_token" ? gh_token : nil
      end

      def source(name)
        name = name.to_s
        return "environment (#{KEYS.fetch(name)})" unless ENV[KEYS.fetch(name)].to_s.strip.empty?
        return path unless read[name].to_s.strip.empty?
        return "gh auth token" if name == "github_token" && gh_token

        nil
      end

      def store(name, value)
        raise ArgumentError, "unknown credential #{name}" unless KEYS.key?(name.to_s)

        data = read
        data[name.to_s] = value.to_s.strip
        write(data)
      end

      def read
        return {} unless File.exist?(path)

        data = YAML.safe_load_file(path) || {}
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end

      private

      def write(data)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory)
        File.chmod(0o700, directory) if File.owned?(directory)
        File.write(path, YAML.dump(data))
        File.chmod(0o600, path)
        path
      end

      def gh_token
        return @gh_token if defined?(@gh_token)

        output, status = Open3.capture2("gh", "auth", "token", err: File::NULL)
        @gh_token = status.success? && !output.strip.empty? ? output.strip : nil
      rescue StandardError
        @gh_token = nil
      end
    end
  end
end
