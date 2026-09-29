# frozen_string_literal: true

require "base64"

module PlanDriven
  # The parts of the GitHub REST API the workflow needs: issues for tickets, and pull requests,
  # their files, CI checks and merge.
  class GitHub
    BASE = "https://api.github.com"

    attr_reader :repository

    def initialize(repository: Repository.slug, token: Credentials.fetch(:github_token), base: BASE)
      @repository = repository or raise ConfigurationError, "No GitHub repository. Set config.github_repository " \
                                                            "or add a GitHub `origin` remote."
      @token = token
      @base = base
    end

    def repo_url
      "https://github.com/#{repository}"
    end

    def create_issue(title:, body:, labels: [])
      request(:post, "/repos/#{repository}/issues", { title: title, body: body, labels: labels })
    end

    def update_issue(number, **fields)
      request(:patch, "/repos/#{repository}/issues/#{number}", fields)
    end

    def comment(number, body)
      request(:post, "/repos/#{repository}/issues/#{number}/comments", { body: body })
    end

    def pull(number)
      request(:get, "/repos/#{repository}/pulls/#{number}")
    end

    def pull_files(number)
      (1..30).each_with_object([]) do |page, files|
        batch = request(:get, "/repos/#{repository}/pulls/#{number}/files?per_page=100&page=#{page}")
        files.concat(batch)
        break files if batch.size < 100
      end
    end

    # Check runs (GitHub Actions and apps) and commit statuses (older CI integrations), in one shape.
    def checks(sha)
      runs = request(:get, "/repos/#{repository}/commits/#{sha}/check-runs?per_page=100")["check_runs"].to_a
      statuses = request(:get, "/repos/#{repository}/commits/#{sha}/status")["statuses"].to_a
      runs.map { |run| run.slice("name", "status", "conclusion") } + statuses.map do |status|
        state = status["state"]
        { "name" => status["context"], "status" => state == "pending" ? "in_progress" : "completed",
          "conclusion" => state == "pending" ? nil : state }
      end
    end

    def file(path, ref:)
      data = request(:get, "/repos/#{repository}/contents/#{path}?ref=#{ref}")
      Base64.decode64(data["content"].to_s)
    end

    def review(number, body:, event: "COMMENT")
      request(:post, "/repos/#{repository}/pulls/#{number}/reviews", { body: body, event: event })
    end

    def merge(number, title:, method:)
      request(:put, "/repos/#{repository}/pulls/#{number}/merge", { commit_title: title, merge_method: method })
    end

    # Agents open draft pull requests, and GitHub won't merge a draft. REST can't undraft; GraphQL can.
    def ready_for_review(number)
      node_id = pull(number)["node_id"]
      data = request(:post, "/graphql", {
                       query: "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) " \
                              "{ pullRequest { isDraft } } }",
                       variables: { id: node_id }
                     })
      raise ProviderError, "GitHub GraphQL: #{data["errors"].map { |e| e["message"] }.join("; ")}" if data["errors"]

      data
    end

    def self.pr_number(url)
      url.to_s[%r{/pull/(\d+)}, 1]&.to_i
    end

    private

    def request(method, path, body = nil)
      unless @token
        raise ConfigurationError,
              "No GitHub token. Run `plan-driven configure`, set GITHUB_TOKEN or `gh auth login`."
      end

      response = HTTP.request(method, "#{@base}#{path}", body: body, headers: {
                                "Authorization" => "Bearer #{@token}",
                                "Accept" => "application/vnd.github+json",
                                "X-GitHub-Api-Version" => "2022-11-28",
                                "Content-Type" => "application/json"
                              })
      return response.json if response.success?

      raise ProviderError,
            "GitHub returned #{response.status} for #{path}: #{response.json["message"] || response.body[0, 200]}"
    end
  end
end
