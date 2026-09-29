# frozen_string_literal: true

module PlanDriven
  # Models wrap JSON in prose or code fences often enough that parsing has to be forgiving,
  # and exact enough that anything else is reported back to the model as an error.
  module JsonReply
    FENCE = /```(?:json)?\s*(.*?)```/m

    module_function

    def parse(text)
      candidates(text.to_s).each do |candidate|
        return JSON.parse(candidate)
      rescue JSON::ParserError
        next
      end
      raise InvalidResponseError, "the reply wasn't valid JSON"
    end

    def candidates(text)
      fenced = text.scan(FENCE).flatten
      braces = text[text.index("{").to_i..(text.rindex("}") || -1)]
      [text, *fenced, braces].compact.map(&:strip).uniq
    end
  end
end
