# frozen_string_literal: true

RSpec.describe PlanDriven::Interview do
  let(:base) { PlanDriven::Template.default }

  def template
    PlanDriven.configuration.template
  end

  it "asks the template's questions while nothing has changed" do
    expect(template.asked.map(&:key)).to eq(base.asked.map(&:key))
    expect(described_class.path).not_to exist
  end

  it "changes a question's wording and keeps its place" do
    expect(described_class.change("who", { "question" => "Who owns it, and who reviews?" }, template: base))
      .to eq(:changed)

    expect(template["who"].question).to eq("Who owns it, and who reviews?")
    expect(template["who"].title).to eq("Who")
    expect(template.asked.map(&:key)).to eq(base.asked.map(&:key))
    expect(described_class.origin("who", template: base)).to eq("changed")
  end

  it "adds a question after the last section of its group, and the plan has a section for it" do
    described_class.change("success_metric", { "title" => "Success metric", "question" => "How will we know it worked?",
                                               "required" => true }, template: base)

    section = template["success_metric"]
    expect(section).to have_attributes(title: "Success metric", group: "Overview", required: true, min_words: 1)
    expect(section).to be_asked
    expect(template.asked.map(&:key)).to eq(%w[what why where who when success_metric background out_of_scope])
    expect(template.grouped["Overview"].map(&:key).last).to eq("success_metric")
  end

  it "makes a question optional or required" do
    described_class.change("where", { "required" => false }, template: base)
    expect(template["where"]).to have_attributes(required: false, min_words: 0)
    expect(template["where"].prompt).to end_with("(optional)")

    described_class.change("background", { "required" => true }, template: base)
    expect(template["background"]).to have_attributes(required: true, min_words: 1)
  end

  it "removes an added question, and puts a changed one back to the default" do
    described_class.change("who", { "question" => "Who?" }, template: base)
    described_class.change("metric", { "title" => "Metric", "question" => "Which number moves?" }, template: base)

    expect(described_class.remove("metric", template: base)).to eq(:removed)
    expect(described_class.remove("who", template: base)).to eq(:reset)
    expect(template["metric"]).to be_nil
    expect(template["who"].question).to eq(base["who"].question)
    expect(described_class.path).not_to exist
  end

  it "writes a file the team can read and commit" do
    described_class.change("who", { "question" => "Who owns it?" }, template: base)

    text = described_class.path.read
    expect(text).to start_with("# The plan_driven interview")
    expect(YAML.safe_load(text)).to eq("questions" => { "who" => { "question" => "Who owns it?" } })
  end

  it "refuses drafted sections, bad keys, unknown groups and half a new question" do
    expect { described_class.change("security", { "question" => "?" }, template: base) }
      .to raise_error(ArgumentError, /drafted by the model/)
    expect { described_class.change("Bad Key", { "question" => "?" }, template: base) }
      .to raise_error(ArgumentError, /isn't a question key/)
    expect { described_class.change("who", { "group" => "Elsewhere" }, template: base) }
      .to raise_error(ArgumentError, /Unknown group/)
    expect { described_class.change("metric", { "question" => "Which number?" }, template: base) }
      .to raise_error(ArgumentError, /needs --title/)
    expect { described_class.change("who", {}, template: base) }.to raise_error(ArgumentError, /Nothing to change/)
    expect { described_class.remove("who", template: base) }.to raise_error(ArgumentError, /no changes/)
  end

  it "picks up a file changed by another process" do
    expect(template["who"].question).to eq(base["who"].question)
    described_class.path.dirname.mkpath
    described_class.path.write("questions:\n  who:\n    question: Edited by hand\n")
    FileUtils.touch(described_class.path, mtime: Time.now + 5)

    expect(template["who"].question).to eq("Edited by hand")
  end

  it "shows (optional) once, whatever the question says" do
    expect(base.asked.map(&:prompt).grep(/\(optional\).*\(optional\)/)).to be_empty
    expect(base["out_of_scope"].prompt).to eq("What is explicitly out of scope? (optional)")
    expect(base["what"].prompt).not_to include("optional")
  end
end
