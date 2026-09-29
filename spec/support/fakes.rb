# frozen_string_literal: true

# Replies queued in order; every call is recorded so specs can read what the model was sent.
class FakeLLM
  attr_reader :calls

  def initialize(*replies)
    @replies = replies.flatten
    @calls = []
  end

  def chat(system:, messages:, **)
    @calls << { system: system, messages: messages.map(&:dup) }
    reply = @replies.shift or raise "FakeLLM ran out of replies"
    PlanDriven::LLM::Reply.new(text: reply.is_a?(String) ? reply : JSON.generate(reply))
  end

  def label
    "fake/model"
  end
end

# Stands in for net/http. Routes match on method and a path regex; requests are recorded.
class FakeTransport
  attr_reader :requests

  def initialize
    @routes = []
    @requests = []
  end

  def on(method, pattern, status: 200, body: {})
    @routes.unshift([method.to_s.upcase, pattern, status, body])
    self
  end

  def call(method, url, headers, body, _timeout)
    @requests << { method: method, url: url, headers: headers, body: body && JSON.parse(body) }
    route = @routes.find { |m, pattern, *| m == method && url.match?(pattern) }
    raise "no fake route for #{method} #{url}" unless route

    payload = route[3].respond_to?(:call) ? route[3].call(@requests.last) : route[3]
    [route[2], payload.is_a?(String) ? payload : JSON.generate(payload)]
  end

  def last(method = nil)
    method ? @requests.reverse.find { |request| request[:method] == method.to_s.upcase } : @requests.last
  end
end

class FakeAgents
  attr_reader :launched, :follow_ups
  attr_accessor :runs

  def initialize
    @launched = []
    @follow_ups = []
    @runs = {}
  end

  def launch(prompt:, repo_url:, name:)
    number = @launched.size + 1
    @launched << { prompt: prompt, repo_url: repo_url, name: name }
    agent = { "id" => "bc-#{number}", "url" => "https://cursor.com/agents/bc-#{number}" }
    [agent, PlanDriven::CursorAgents::Run.new(id: "run-#{number}", agent_id: agent["id"], status: "CREATING")]
  end

  def run(agent_id, run_id)
    @runs.fetch([agent_id, run_id]) { PlanDriven::CursorAgents::Run.new(id: run_id, agent_id: agent_id, status: "RUNNING") }
  end

  def follow_up(agent_id, text)
    @follow_ups << { agent_id: agent_id, text: text }
    PlanDriven::CursorAgents::Run.new(id: "run-f#{@follow_ups.size}", agent_id: agent_id, status: "CREATING")
  end

  def finish(ticket, pr: 100)
    @runs[[ticket.agent_id, ticket.agent_run_id]] =
      PlanDriven::CursorAgents::Run.new(id: ticket.agent_run_id, agent_id: ticket.agent_id, status: "FINISHED",
                                        branch: "cursor/#{ticket.key.downcase}",
                                        pr_url: "https://github.com/acme/app/pull/#{pr}")
  end
end

class FakeGitHub
  attr_reader :issues, :reviews, :merged, :comments, :check_results
  attr_accessor :pulls, :files, :contents

  def initialize
    @issues = []
    @reviews = []
    @merged = []
    @comments = []
    @pulls = {}
    @files = {}
    @check_results = {}
    @contents = {}
  end

  def repo_url = "https://github.com/acme/app"

  def create_issue(title:, body:, labels:)
    @issues << { title: title, body: body, labels: labels }
    { "number" => 10 + @issues.size }
  end

  def pull(number)
    @pulls.fetch(number) { { "number" => number, "title" => "", "body" => "", "head" => { "sha" => "sha#{number}" } } }
  end

  def pull_files(number) = @files.fetch(number, [])
  def checks(sha) = @check_results.fetch(sha, [{ "name" => "CI", "status" => "completed", "conclusion" => "success" }])
  def file(path, ref:) = @contents.fetch([path, ref], "")

  def review(number, body:, event: "COMMENT")
    @reviews << { number: number, body: body, event: event }
  end

  def ready_for_review(number)
    @pulls[number] = pull(number).merge("draft" => false)
  end

  def merge(number, title:, method:)
    raise PlanDriven::ProviderError, "Pull Request is still a draft" if pull(number)["draft"]

    @merged << { number: number, title: title, method: method }
    { "sha" => "merge#{number}sha" }
  end
end
