# frozen_string_literal: true

RSpec.describe PlanDriven::LLM do
  let(:transport) { FakeTransport.new }
  let(:config) { PlanDriven.configuration }

  before do
    PlanDriven::HTTP.transport = transport
    allow(PlanDriven::Credentials).to receive(:fetch).and_call_original
    allow(PlanDriven::Credentials).to receive(:fetch).with(:openai_api_key).and_return("sk-test")
    allow(PlanDriven::Credentials).to receive(:fetch).with(:anthropic_api_key).and_return("sk-ant-test")
  end

  it "calls OpenAI chat completions in JSON mode with the configured model" do
    transport.on(:post, %r{api.openai.com/v1/chat/completions},
                 body: { choices: [{ message: { content: '{"ok":true}' } }], usage: { prompt_tokens: 5, completion_tokens: 2 } })
    reply = described_class.new.chat(system: "sys", messages: [{ role: "user", content: "hi" }])

    expect(reply.text).to eq('{"ok":true}')
    expect(reply.output_tokens).to eq(2)
    request = transport.last
    expect(request[:headers]["Authorization"]).to eq("Bearer sk-test")
    expect(request[:body]).to include("model" => "gpt-4.1", "response_format" => { "type" => "json_object" })
    expect(request[:body]["messages"].first).to eq("role" => "system", "content" => "sys")
  end

  it "calls Anthropic messages when configured" do
    config.llm_provider = :anthropic
    transport.on(:post, %r{api.anthropic.com/v1/messages}, body: { content: [{ type: "text", text: "{}" }] })
    described_class.new.chat(system: "sys", messages: [{ role: "user", content: "hi" }])

    request = transport.last
    expect(request[:headers]).to include("x-api-key" => "sk-ant-test", "anthropic-version" => "2023-06-01")
    expect(request[:body]).to include("model" => "claude-sonnet-4-5", "system" => "sys")
  end

  it "uses a configured model and API base" do
    config.llm_model = "o3"
    config.llm_api_base = "https://llm.internal/v1"
    transport.on(:post, %r{llm.internal/v1/chat/completions}, body: { choices: [{ message: { content: "{}" } }] })
    described_class.new.chat(system: "s", messages: [])
    expect(transport.last[:body]["model"]).to eq("o3")
  end

  it "reports provider errors with their message" do
    transport.on(:post, /openai/, status: 401, body: { error: { message: "Incorrect API key" } })
    expect { described_class.new.chat(system: "s", messages: []) }
      .to raise_error(PlanDriven::ProviderError, "openai returned 401: Incorrect API key")
  end

  it "explains how to add a missing key" do
    allow(PlanDriven::Credentials).to receive(:fetch).with(:openai_api_key).and_return(nil)
    expect { described_class.new.chat(system: "s", messages: []) }
      .to raise_error(PlanDriven::ConfigurationError, /plan-driven configure.*OPENAI_API_KEY/)
  end

  it "uses an injected client" do
    llm = described_class.new(client: ->(system:, messages:) { "#{system}:#{messages.size}" })
    expect(llm.chat(system: "s", messages: [1, 2]).text).to eq("s:2")
  end

  it "labels itself with provider and model" do
    expect(described_class.new.label).to eq("openai/gpt-4.1")
  end

  describe "through a Cursor agent" do
    let(:dir) { Pathname(Dir.mktmpdir) }

    # Stands in for `node cursor_llm.mjs`: records its input and key, answers like the bridge.
    def fake_node(reply, exit_code: 0)
      script = dir.join("node")
      script.write(<<~SH)
        #!/bin/sh
        cat > "#{dir}/input.json"
        printf '%s' "$CURSOR_API_KEY" > "#{dir}/key"
        printf '%s' '#{JSON.generate(reply)}'
        exit #{exit_code}
      SH
      script.chmod(0o755)
      config.node_command = script.to_s
    end

    before do
      config.llm_provider = :cursor
      allow(PlanDriven::Credentials).to receive(:fetch).with(:cursor_api_key).and_return("crsr-test")
    end

    it "drafts with Opus on the Cursor account by default, reading the app read-only" do
      fake_node({ text: '{"ok":true}', usage: { input: 10, output: 3 } })
      reply = described_class.new.chat(system: "Write a plan.", messages: [{ role: "user", content: "Q&A" }])

      expect(reply.text).to eq('{"ok":true}')
      expect(reply.output_tokens).to eq(3)
      input = JSON.parse(dir.join("input.json").read)
      expect(input).to include("model" => "claude-opus-5-5", "cwd" => config.root_path.to_s)
      expect(input["prompt"]).to include("Write a plan.", "## user\n\nQ&A", "Don't try to change files")
      expect(dir.join("key").read).to eq("crsr-test")
      expect(described_class.new.label).to eq("cursor/claude-opus-5-5")
    end

    it "reports what the agent or SDK said when it fails" do
      fake_node({ error: "@cursor/sdk not found" }, exit_code: 1)
      expect { described_class.new.chat(system: "s", messages: []) }
        .to raise_error(PlanDriven::ProviderError, "cursor: @cursor/sdk not found")
    end

    it "needs the Cursor key" do
      allow(PlanDriven::Credentials).to receive(:fetch).with(:cursor_api_key).and_return(nil)
      expect { described_class.new.chat(system: "s", messages: []) }
        .to raise_error(PlanDriven::ConfigurationError, /CURSOR_API_KEY/)
    end

    it "explains a missing Node" do
      config.node_command = dir.join("no-node").to_s
      expect { described_class.new.chat(system: "s", messages: []) }
        .to raise_error(PlanDriven::ConfigurationError, /Node 22.13\+/)
    end
  end
end
