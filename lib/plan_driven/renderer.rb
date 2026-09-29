# frozen_string_literal: true

require "cgi"
require "fileutils"

require_relative "renderer/markdown"
require_relative "renderer/html"
require_relative "renderer/pdf"

module PlanDriven
  # Writes a plan's documentation under docs/plans/<plan-slug>/: the plan and the delivery report,
  # each as Markdown (for the repository), HTML and PDF (for people who don't read Markdown).
  module Renderer
    module_function

    def write_plan(plan, config: PlanDriven.configuration)
      write(plan, "plan", Markdown.plan(plan, config: config), title: "#{plan.key} #{plan.title}", config: config)
    end

    def write_report(plan, config: PlanDriven.configuration)
      write(plan, "delivery-report", Markdown.report(plan),
            title: "#{plan.key} delivery report", config: config)
    end

    def directory(plan, config: PlanDriven.configuration)
      config.docs_root.join(plan.slug)
    end

    def write(plan, name, markdown, title:, config:)
      dir = directory(plan, config: config)
      FileUtils.mkdir_p(dir)
      md = dir.join("#{name}.md")
      html = dir.join("#{name}.html")
      pdf = dir.join("#{name}.pdf")
      File.write(md, markdown)
      File.write(html, HTML.document(markdown, title: title))
      written = PDF.render(html, pdf, config: config)
      { markdown: md, html: html, pdf: written ? pdf : nil }
    end
  end
end
