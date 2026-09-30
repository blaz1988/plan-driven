# frozen_string_literal: true

require "open3"

RSpec.describe PlanDriven::LocalAgents do
  let(:github) { FakeGitHub.new }
  let(:config) { PlanDriven.configuration }
  let(:agents) { described_class.new(config: config, github: github) }

  def sh(*args, dir: root)
    out, status = Open3.capture2e(*args, chdir: dir.to_s)
    raise "#{args.join(" ")}: #{out}" unless status.success?

    out
  end

  def agent_script(body)
    path = root.join("agent.sh")
    File.write(path, "#!/bin/sh\ncat > /dev/null\n#{body}\n")
    File.chmod(0o755, path)
    config.agent_command = path.to_s
  end

  def wait(agent_id, run_id)
    50.times do
      run = agents.run(agent_id, run_id)
      return run unless run.status == "RUNNING"

      sleep 0.1
    end
    raise "the agent never finished"
  end

  around do |example|
    Dir.mktmpdir do |origin|
      @origin = origin
      example.run
    end
  end

  before do
    config.agent_provider = :local
    sh("git", "init", "--quiet", "--bare", "--initial-branch=main", @origin)
    File.write(root.join(".gitignore"), "tmp/\nagent.sh\n")
    sh("git", "init", "--quiet", "--initial-branch=main")
    sh("git", "config", "user.email", "ada@example.com")
    sh("git", "config", "user.name", "Ada")
    sh("git", "add", "--all")
    sh("git", "commit", "--quiet", "-m", "App")
    sh("git", "remote", "add", "origin", @origin)
    sh("git", "push", "--quiet", "origin", "main")
  end

  it "runs the command in its own worktree, then pushes the branch and opens the pull request" do
    agent_script(<<~SH)
      echo "class Rating; end" > app/models/rating.rb
      printf 'PD-1/T1\\n- [x] 1. Ratings exist' > PR_DESCRIPTION.md
      echo '{"type":"result","usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":11,"cache_read_input_tokens":13}}'
    SH
    agent, run = agents.launch(prompt: "Implement T1", repo_url: "https://github.com/acme/app", name: "[PD-1/T1] Ratings")
    expect(run.status).to eq("RUNNING")

    run = wait(agent["id"], run.id)
    expect(run.status).to eq("FINISHED"), run.result
    expect(run.pr_url).to eq("https://github.com/acme/app/pull/200")
    expect(run.branch).to start_with("plan-driven/pd-1-t1-ratings-")
    pull = github.pulls[200]
    expect(pull).to include("title" => "[PD-1/T1] Ratings", "body" => "PD-1/T1\n- [x] 1. Ratings exist")
    expect(pull.dig("base", "ref")).to eq("main")

    files = sh("git", "ls-tree", "-r", "--name-only", run.branch, dir: @origin)
    expect(files).to include("app/models/rating.rb")
    expect(files).not_to include("PR_DESCRIPTION.md")
    expect(root.join("tmp/plan_driven/agents/#{run.id}.prompt").read).to include("Implement T1", "Don't push")
    expect(agents.usage(agent["id"], run.id)).to eq("input_tokens" => 5, "output_tokens" => 7,
                                                    "cache_write_tokens" => 11, "cache_read_tokens" => 13)
  end

  it "passes the prompt as a file when the command asks for {prompt_file}" do
    agent_script('cp "$1" app/models/prompt.txt')
    config.agent_command = "#{config.agent_command} {prompt_file}"
    agent, run = agents.launch(prompt: "Implement T1", repo_url: "", name: "T1")
    run = wait(agent["id"], run.id)
    expect(sh("git", "show", "#{run.branch}:app/models/prompt.txt", dir: @origin)).to start_with("Implement T1")
  end

  it "pushes a follow-up to the same pull request" do
    agent_script('echo "$(date +%s%N)" >> app/models/rating.rb')
    agent, run = agents.launch(prompt: "Implement T1", repo_url: "", name: "[PD-1/T1] Ratings")
    first = wait(agent["id"], run.id)
    follow = wait(agent["id"], agents.follow_up(agent["id"], "Rename it").id)
    expect(follow.status).to eq("FINISHED")
    expect(follow.pr_url).to eq(first.pr_url)
    expect(github.pulls.size).to eq(1)
    expect(sh("git", "rev-list", "--count", "main..#{first.branch}", dir: @origin).strip).to eq("2")
  end

  it "removes the worktree and local branch once the work is merged" do
    agent_script('echo "class Rating; end" > app/models/rating.rb')
    agent, run = agents.launch(prompt: "x", repo_url: "", name: "T1")
    run = wait(agent["id"], run.id)
    dir = root.join("tmp/plan_driven/agents", agent["id"])
    expect(dir).to exist
    agents.cleanup(agent["id"])
    expect(dir).not_to exist
    expect(sh("git", "branch", "--list", run.branch)).to eq("")
    expect(sh("git", "ls-remote", "--heads", "origin", run.branch)).to include(run.branch)
  end

  it "fails the run when the command fails, or changes nothing" do
    agent_script("echo 'model overloaded' >&2\nexit 3")
    agent, run = agents.launch(prompt: "x", repo_url: "", name: "T1")
    expect(wait(agent["id"], run.id)).to have_attributes(status: "ERROR", result: /exited with 3: model overloaded/)

    agent_script("true")
    agent, run = agents.launch(prompt: "x", repo_url: "", name: "T2")
    expect(wait(agent["id"], run.id)).to have_attributes(status: "ERROR", result: /without changing anything/)
    expect(github.pulls).to be_empty
  end

  it "stops a run that takes longer than config.agent_timeout" do
    config.agent_timeout = -1
    agent_script("sleep 30")
    agent, run = agents.launch(prompt: "x", repo_url: "", name: "T1")
    expect(agents.run(agent["id"], run.id)).to have_attributes(status: "EXPIRED")
  end

  it "needs a command" do
    config.agent_command = nil
    expect { agents.launch(prompt: "x", repo_url: "", name: "T1") }
      .to raise_error(PlanDriven::ConfigurationError, /config.agent_command/)
  end

  it "is what Delivery uses when the provider is :local" do
    expect(PlanDriven::Agents.build(config)).to be_a(described_class)
    config.agent_provider = :cursor
    expect(PlanDriven::Agents.build(config)).to be_a(PlanDriven::CursorAgents)
    config.agent_provider = :devin
    expect { PlanDriven::Agents.build(config) }.to raise_error(PlanDriven::ConfigurationError, /:cursor or :local/)
  end
end
