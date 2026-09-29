# frozen_string_literal: true

module PlanDriven
  # Just enough Gherkin to know which scenarios exist and how they're tagged. Tags on the
  # Feature line apply to every scenario in it, as they do in Cucumber.
  module Gherkin
    Scenario = Struct.new(:name, :tags, :line, :path, :steps, keyword_init: true)
    Feature = Struct.new(:name, :tags, :path, :scenarios, keyword_init: true)

    SCENARIO = /\A\s*(Scenario(?: Outline| Template)?|Example):\s*(.*)\z/
    FEATURE = /\A\s*(Feature|Ability|Business Need):\s*(.*)\z/
    STEP = /\A\s*(Given|When|Then|And|But|\*)\s+(.*)\z/

    module_function

    def parse(text, path: nil)
      state = { feature: Feature.new(name: nil, tags: [], path: path, scenarios: []), tags: [], scenario: nil }
      text.to_s.each_line.with_index(1) { |raw, number| read_line(state, raw.strip, number) }
      state[:feature]
    end

    def read_line(state, line, number)
      return if line.empty? || line.start_with?("#")

      feature = state[:feature]
      if line.start_with?("@")
        state[:tags].concat(line.split(/\s+/).grep(/\A@/))
      elsif (match = line.match(FEATURE))
        feature.name = match[2].strip
        feature.tags = state.delete(:tags)
        state[:tags] = []
      elsif (match = line.match(SCENARIO))
        state[:scenario] = Scenario.new(name: match[2].strip, tags: (feature.tags + state[:tags]).uniq, line: number,
                                        path: feature.path, steps: [])
        feature.scenarios << state[:scenario]
        state[:tags] = []
      elsif state[:scenario] && (match = line.match(STEP))
        state[:scenario].steps << "#{match[1]} #{match[2]}"
      end
    end
  end
end
