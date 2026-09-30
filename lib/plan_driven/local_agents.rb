# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "shellwords"

module PlanDriven
  # Which coding agents take the tickets: config.agent_provider.
  module Agents
    def self.build(config = PlanDriven.configuration)
      case config.agent_provider.to_sym
      when :cursor then CursorAgents.new(config: config)
      when :local then LocalAgents.new(config: config)
      else raise ConfigurationError, "config.agent_provider is #{config.agent_provider.inspect}; use :cursor or :local"
      end
    end
  end

  # Runs a coding agent CLI on this machine: Claude Code, Codex, the Cursor CLI, or anything else
  # that edits the files in its working directory. The prompt arrives on stdin, or wherever the
  # command says `{prompt_file}`.
  #
  #   config.agent_provider = :local
  #   config.agent_command = "claude -p --permission-mode acceptEdits --output-format json"
  #   config.agent_command = "codex exec --full-auto -"
  #   config.agent_command = 'cursor-agent -p --force --output-format json "$(cat {prompt_file})"'
  #
  # Each ticket gets its own git worktree and branch under tmp/plan_driven/agents. When the
  # command exits cleanly, plan_driven commits what it left, pushes the branch and opens the pull
  # request, so the rest of the workflow (review, feedback, merge) is the same as with Cursor.
  class LocalAgents
    PR_BODY = "PR_DESCRIPTION.md"
    INSTRUCTIONS = <<~TEXT.freeze
      # Working locally
      You are in a git worktree on the ticket's own branch. Don't push and don't open the pull request:
      plan_driven does both when you finish. Write the pull request description (the part described
      above) to `#{PR_BODY}` in the repository root; it becomes the pull request body and isn't committed.
      Committing is optional, anything you leave uncommitted is committed for you.
    TEXT

    Run = CursorAgents::Run

    def initialize(config: PlanDriven.configuration, github: nil)
      @config = config
      @github = github
    end

    def launch(prompt:, repo_url:, name:) # rubocop:disable Lint/UnusedMethodArgument
      command!
      id = "local-#{SecureRandom.hex(4)}"
      state = { "id" => id, "name" => name, "branch" => "plan-driven/#{slug(name)}-#{id.delete_prefix("local-")}",
                "dir" => root.join(id).to_s, "runs" => [] }
      git(@config.root_path, "fetch", "--quiet", "origin", @config.base_branch)
      git(@config.root_path, "worktree", "add", "--quiet", "-b", state["branch"], state["dir"],
          "origin/#{@config.base_branch}")
      run = start(state, "#{prompt}\n\n#{INSTRUCTIONS}")
      [{ "id" => id, "url" => nil }, run]
    end

    def run(agent_id, run_id)
      state = load(agent_id)
      entry = state["runs"].find { |item| item["id"] == run_id } or raise ProviderError, "no local run #{run_id}"
      return to_run(state, entry) if entry["status"]

      exit_file = Pathname(entry["exit_file"])
      if !exit_file.exist? && alive?(entry["pid"])
        return to_run(state, entry, "RUNNING") unless overdue?(entry)

        stop(entry["pid"])
        return settle(state, entry, "EXPIRED", "stopped after #{@config.agent_timeout}s (config.agent_timeout)")
      end

      code = exit_file.exist? ? exit_file.read.strip.to_i : 1
      unless code.zero?
        return settle(state, entry, "ERROR",
                      "the agent command exited with #{code}: #{log_tail(entry)}")
      end

      publish(state, entry)
    end

    def follow_up(agent_id, text)
      state = load(agent_id)
      start(state, "#{text}\n\n#{INSTRUCTIONS}")
    end

    # Tokens, when the command reports them the way Claude Code's `--output-format json` does.
    def usage(agent_id, run_id)
      entry = load(agent_id)["runs"].find { |item| item["id"] == run_id }
      data = entry && reported_usage(Pathname(entry["log"]))
      return {} unless data

      { "input_tokens" => data["input_tokens"].to_i, "output_tokens" => data["output_tokens"].to_i,
        "cache_write_tokens" => data["cache_creation_input_tokens"].to_i,
        "cache_read_tokens" => data["cache_read_input_tokens"].to_i }
    end

    # Once the pull request is merged, the worktree and its local branch go.
    def cleanup(agent_id)
      state = load(agent_id)
      git(@config.root_path, "worktree", "remove", "--force", state["dir"]) if Dir.exist?(state["dir"])
      git_ok?(@config.root_path, "branch", "-D", state["branch"])
    rescue ProviderError
      nil
    end

    def me
      { "apiKeyName" => "local: #{command!}" }
    end

    def model_ids
      []
    end

    private

    def start(state, prompt)
      number = state["runs"].size + 1
      base = root.join("#{state["id"]}-run-#{number}")
      File.write("#{base}.prompt", prompt)
      prompt_file = Shellwords.escape("#{base}.prompt")
      agent = if command!.include?("{prompt_file}")
                "#{command!.gsub("{prompt_file}", prompt_file)} < /dev/null"
              else
                "#{command!} < #{prompt_file}"
              end
      script = "#{agent} > #{Shellwords.escape("#{base}.log")} 2>&1; echo $? > #{Shellwords.escape("#{base}.exit")}"
      pid = Process.spawn("sh", "-c", script, chdir: state["dir"], pgroup: true, in: File::NULL)
      Process.detach(pid)
      entry = { "id" => "#{state["id"]}-run-#{number}", "pid" => pid, "started_at" => Time.now.to_i,
                "log" => "#{base}.log", "exit_file" => "#{base}.exit" }
      state["runs"] << entry
      save(state)
      to_run(state, entry, "RUNNING")
    end

    # Commit, push, and open the pull request the first time; later runs push to the same one.
    def publish(state, entry)
      dir = Pathname(state["dir"])
      body = commit_all(dir, state["name"])
      if git(dir, "rev-list", "--count", "origin/#{@config.base_branch}..HEAD").strip == "0"
        return settle(state, entry, "ERROR", "the agent finished without changing anything: #{log_tail(entry)}")
      end

      git(dir, "push", "--quiet", "--set-upstream", "origin", state["branch"])
      state["pr_url"] ||= github.create_pull(title: state["name"], head: state["branch"], base: @config.base_branch,
                                             body: body || state["name"])["html_url"]
      settle(state, entry, "FINISHED", body.to_s[0, 500])
    rescue ProviderError => e
      settle(state, entry, "ERROR", e.message)
    end

    # Commits what the agent left, without its pull request description, which is returned.
    def commit_all(dir, message)
      body_file = dir.join(PR_BODY)
      body = body_file.exist? ? body_file.read : nil
      FileUtils.rm_f(body_file)
      git(dir, "add", "--all")
      git(dir, "commit", "--quiet", "-m", message) unless git_ok?(dir, "diff", "--cached", "--quiet")
      body
    end

    def settle(state, entry, status, result)
      entry["status"] = status
      entry["result"] = result
      entry["duration_ms"] = (Time.now.to_i - entry["started_at"]) * 1000
      save(state)
      to_run(state, entry)
    end

    def to_run(state, entry, status = entry["status"])
      Run.new(id: entry["id"], agent_id: state["id"], status: status, result: entry["result"],
              branch: state["branch"], pr_url: status == "FINISHED" ? state["pr_url"] : nil,
              duration_ms: entry["duration_ms"])
    end

    def reported_usage(log)
      return unless log.exist?

      log.read.lines.reverse_each do |line|
        data = JSON.parse(line)
        return data["usage"] if data.is_a?(Hash) && data["usage"].is_a?(Hash)
      rescue JSON::ParserError
        next
      end
      nil
    end

    def command!
      @config.agent_command.presence or
        raise ConfigurationError, "config.agent_provider is :local, so set config.agent_command, for example " \
                                  "\"claude -p --permission-mode acceptEdits --output-format json\""
    end

    def git(dir, *args)
      out, status = Open3.capture2e("git", *args, chdir: dir.to_s)
      raise ProviderError, "git #{args.first} failed: #{out.strip.last(300)}" unless status.success?

      out
    end

    def git_ok?(dir, *args)
      _out, status = Open3.capture2e("git", *args, chdir: dir.to_s)
      status.success?
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def overdue?(entry)
      Time.now.to_i - entry["started_at"] > @config.agent_timeout.to_i
    end

    def stop(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def log_tail(entry)
      log = Pathname(entry["log"])
      log.exist? ? log.read.strip.last(300) : "no output"
    end

    def slug(name)
      name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40]
    end

    def root
      @config.root_path.join("tmp/plan_driven/agents").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    def load(agent_id)
      path = root.join("#{agent_id}.json")
      raise ProviderError, "no local agent #{agent_id} (#{path} is missing)" unless path.exist?

      JSON.parse(path.read)
    end

    def save(state)
      File.write(root.join("#{state["id"]}.json"), JSON.pretty_generate(state))
    end

    def github
      @github ||= GitHub.new
    end
  end
end
