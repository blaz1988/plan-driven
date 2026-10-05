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

    # The data model diagram is an SVG beside the plan, like the report's charts.
    def write_plan(plan, config: PlanDriven.configuration, schema: nil)
      dir = directory(plan, config: config)
      FileUtils.mkdir_p(dir)
      diagram = DataModel.write(plan, dir, schema: schema || SchemaContext.new, config: config)
      images = diagram ? { DataModel::FILE => diagram.read } : {}
      write(plan, "plan", Markdown.plan(plan, config: config, diagram: !diagram.nil?),
            title: "#{plan.key} #{plan.title}", config: config, images: images)
    end

    # The charts are SVG files beside the report, so GitHub shows them in the Markdown; the HTML
    # and the PDF carry them inline.
    def write_report(plan, config: PlanDriven.configuration)
      charts = Charts.report(plan)
      dir = directory(plan, config: config)
      FileUtils.mkdir_p(dir)
      Dir[dir.join("statistics-*.svg")].each { |file| File.delete(file) }
      charts.each { |name, svg| File.write(dir.join(name), svg) }
      write(plan, "delivery-report", Markdown.report(plan, charts: charts.keys),
            title: "#{plan.key} delivery report", config: config, images: charts)
    end

    def directory(plan, config: PlanDriven.configuration)
      config.docs_root.join(plan.slug)
    end

    def write(plan, name, markdown, title:, config:, images: {})
      dir = directory(plan, config: config)
      FileUtils.mkdir_p(dir)
      md = dir.join("#{name}.md")
      html = dir.join("#{name}.html")
      pdf = dir.join("#{name}.pdf")
      File.write(md, markdown)
      File.write(html, HTML.document(markdown, title: title, images: images))
      written = PDF.render(html, pdf, config: config)
      { markdown: md, html: html, pdf: written ? pdf : nil }
    end
  end
end
