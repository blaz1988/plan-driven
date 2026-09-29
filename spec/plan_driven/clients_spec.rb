# frozen_string_literal: true

RSpec.describe "API clients" do
  let(:transport) { FakeTransport.new }

  before { PlanDriven::HTTP.transport = transport }

  describe PlanDriven::CursorAgents do
    subject(:agents) { described_class.new(api_key: "key_test") }

    it "launches an agent that opens a pull request" do
      transport.on(:post, %r{api.cursor.com/v1/agents\z},
                   body: { agent: { id: "bc-1", url: "https://cursor.com/agents/bc-1" }, run: { id: "run-1", status: "CREATING" } })
      agent, run = agents.launch(prompt: "Do T1", repo_url: "https://github.com/acme/app", name: "[PD-1/T1] Add")

      expect(agent["id"]).to eq("bc-1")
      expect(run.id).to eq("run-1")
      expect(transport.last[:headers]["Authorization"]).to eq("Basic #{Base64.strict_encode64("key_test:")}")
      expect(transport.last[:body]).to eq(
        "prompt" => { "text" => "Do T1" }, "name" => "[PD-1/T1] Add", "autoCreatePR" => true,
        "repos" => [{ "url" => "https://github.com/acme/app", "startingRef" => "main" }], "skipReviewerRequest" => false
      )
    end

    it "sends the configured agent model" do
      PlanDriven.configuration.agent_model = "composer-2"
      transport.on(:post, /agents/, body: { agent: { id: "a" }, run: { id: "r" } })
      agents.launch(prompt: "p", repo_url: "u", name: "n")
      expect(transport.last[:body]["model"]).to eq("id" => "composer-2")
    end

    it "reads a finished run's branch and pull request" do
      transport.on(:get, %r{/agents/bc-1/runs/run-1},
                   body: { id: "run-1", agentId: "bc-1", status: "FINISHED",
                           git: { branches: [{ branch: "cursor/t1", prUrl: "https://github.com/acme/app/pull/7" }] } })
      run = agents.run("bc-1", "run-1")
      expect(run).to be_finished
      expect(run).to be_terminal
      expect([run.branch, run.pr_url]).to eq(["cursor/t1", "https://github.com/acme/app/pull/7"])
    end

    it "sends a follow-up" do
      transport.on(:post, %r{/agents/bc-1/runs\z}, body: { run: { id: "run-2", status: "CREATING" } })
      expect(agents.follow_up("bc-1", "fix it").id).to eq("run-2")
      expect(transport.last[:body]).to eq("prompt" => { "text" => "fix it" })
    end

    it "reports API errors" do
      transport.on(:post, %r{/runs\z}, status: 409,
                                       body: { error: { code: "agent_busy", message: "Agent is running" } })
      expect do
        agents.follow_up("bc-1", "x")
      end.to raise_error(PlanDriven::ProviderError, "Cursor API returned 409: Agent is running")
    end

    it "lists the model IDs and aliases agents can use" do
      transport.on(:get, %r{/v1/models\z}, body: { items: [{ id: "composer-2.5", aliases: ["composer"] }, { id: "default" }] })
      expect(agents.model_ids).to eq(%w[composer-2.5 composer default])
    end

    it "needs a key" do
      expect { described_class.new(api_key: nil).me }.to raise_error(PlanDriven::ConfigurationError, /CURSOR_API_KEY/)
    end
  end

  describe PlanDriven::GitHub do
    subject(:github) { described_class.new(repository: "acme/app", token: "ghp_test") }

    it "creates issues" do
      transport.on(:post, %r{/repos/acme/app/issues\z}, status: 201, body: { number: 12 })
      expect(github.create_issue(title: "T", body: "B", labels: ["plan-driven"])["number"]).to eq(12)
      expect(transport.last[:headers]).to include("Authorization" => "Bearer ghp_test",
                                                  "X-GitHub-Api-Version" => "2022-11-28")
    end

    it "pages through pull request files" do
      page = ->(n) { Array.new(n) { |i| { "filename" => "f#{i}.rb" } } }
      transport.on(:get, /files\?per_page=100&page=1\z/, body: page.call(100))
      transport.on(:get, /files\?per_page=100&page=2\z/, body: page.call(3))
      expect(github.pull_files(7).size).to eq(103)
    end

    it "combines check runs and commit statuses" do
      transport.on(:get, %r{/commits/abc/check-runs},
                   body: { check_runs: [{ name: "rspec", status: "completed", conclusion: "success" }] })
      transport.on(:get, %r{/commits/abc/status\z}, body: { statuses: [{ context: "ci/circle", state: "pending" },
                                                                       { context: "lint", state: "failure" }] })
      expect(github.checks("abc")).to eq([
                                           { "name" => "rspec", "status" => "completed", "conclusion" => "success" },
                                           { "name" => "ci/circle", "status" => "in_progress", "conclusion" => nil },
                                           { "name" => "lint", "status" => "completed", "conclusion" => "failure" }
                                         ])
    end

    it "reads a file at a commit" do
      transport.on(:get, %r{/contents/features/a.feature\?ref=abc}, body: { content: Base64.encode64("Feature: A") })
      expect(github.file("features/a.feature", ref: "abc")).to eq("Feature: A")
    end

    it "squash merges" do
      transport.on(:put, %r{/pulls/7/merge\z}, body: { sha: "m1", merged: true })
      expect(github.merge(7, title: "Add (PD-1/T1)", method: "squash")["sha"]).to eq("m1")
      expect(transport.last[:body]).to eq("commit_title" => "Add (PD-1/T1)", "merge_method" => "squash")
    end

    it "reports errors with GitHub's message" do
      transport.on(:put, /merge/, status: 405, body: { message: "Pull Request is not mergeable" })
      expect do
        github.merge(7, title: "x", method: "squash")
      end.to raise_error(PlanDriven::ProviderError, /405.*not mergeable/)
    end

    it "reads the number from a pull request URL" do
      expect(described_class.pr_number("https://github.com/acme/app/pull/42")).to eq(42)
      expect(described_class.pr_number(nil)).to be_nil
    end
  end

  describe PlanDriven::HTTP do
    it "turns network failures into provider errors" do
      described_class.transport = ->(*) { raise SocketError, "getaddrinfo failed" }
      expect { described_class.request(:get, "https://api.example.com/x") }
        .to raise_error(PlanDriven::ProviderError, "Could not reach api.example.com: getaddrinfo failed")
    end

    it "reads non-JSON bodies as empty JSON" do
      described_class.transport = ->(*) { [502, "<html>Bad gateway</html>"] }
      response = described_class.request(:get, "https://api.example.com/x")
      expect(response).not_to be_success
      expect(response.json).to eq({})
    end
  end
end
