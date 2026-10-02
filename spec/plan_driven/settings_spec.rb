# frozen_string_literal: true

RSpec.describe PlanDriven::Settings do
  let(:config) { PlanDriven.configuration }

  it "uses the recommended practice while nothing has changed" do
    expect(config).to have_attributes(ticket_split: "small", max_tickets: nil, max_estimate: 5, separate_migrations: true,
                                      max_pr_changed_lines: 800, require_specs_in_pr: true, cucumber: true,
                                      targeted_tests: true, max_parallel_agents: 3)
    expect(described_class.path).not_to exist
    expect(described_class.keys.map { |key| described_class.origin(key) }.uniq).to eq(["default"])
  end

  it "stores what was typed, and the file wins over the initializer" do
    config.max_pr_changed_lines = 600
    expect(described_class.origin("max_pr_changed_lines")).to eq("initializer")

    expect(described_class.change("separate_migrations", "off")).to be(false)
    expect(described_class.change("max_tickets", "4")).to eq(4)
    expect(described_class.change("max_pr_changed_lines", "1200")).to eq(1200)
    expect(described_class.change("ticket_split", "Larger")).to eq("larger")

    expect(config).to have_attributes(separate_migrations: false, max_tickets: 4, max_pr_changed_lines: 1200,
                                      ticket_split: "larger")
    expect(described_class.origin("max_pr_changed_lines")).to eq("settings")
    expect(described_class.path.read).to start_with(described_class::HEADER).and include("separate_migrations: false")
  end

  it "puts a setting back, and removes the file once nothing is changed" do
    config.max_parallel_agents = 2
    described_class.change("max_parallel_agents", "5")
    expect(config.max_parallel_agents).to eq(5)

    described_class.reset("max_parallel_agents")
    expect(config.max_parallel_agents).to eq(2)
    expect(described_class.path).not_to exist
    expect { described_class.reset("max_parallel_agents") }.to raise_error(ArgumentError, /isn't changed/)
  end

  it "takes none for no limit" do
    described_class.change("max_tickets", "3")
    expect(described_class.change("max_tickets", "none")).to be_nil
    expect(config.max_tickets).to be_nil
    expect(described_class.origin("max_tickets")).to eq("settings")
  end

  it "rejects values that don't fit the option" do
    expect { described_class.change("separate_migrations", "maybe") }.to raise_error(ArgumentError, /on or off/)
    expect { described_class.change("ticket_split", "huge") }.to raise_error(ArgumentError, /small, larger/)
    expect { described_class.change("max_pr_changed_lines", "10") }.to raise_error(ArgumentError, /at least 50/)
    expect { described_class.change("max_estimate", "none") }.to raise_error(ArgumentError, /whole number/)
    expect { described_class.change("llm_model", "gpt") }.to raise_error(ArgumentError, /Unknown setting/)
  end

  it "says which file is wrong when it was edited by hand" do
    FileUtils.mkdir_p(described_class.path.dirname)
    described_class.path.write("settings:\n  cucumber: sometimes\n")
    expect { config.cucumber }.to raise_error(PlanDriven::ConfigurationError, /settings\.yml: cucumber is on or off/)
  end

  it "explains what every option trades off" do
    described_class::OPTIONS.each do |option|
      expect(option.explanation).to be_present
      expect(option.tradeoff).to be_present
      expect(described_class.recommended(option.key)).to eq(PlanDriven::Configuration.new.public_send(option.key))
    end
  end
end
