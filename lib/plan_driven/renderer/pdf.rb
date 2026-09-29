# frozen_string_literal: true

module PlanDriven
  module Renderer
    # Prints the HTML to PDF with headless Chrome or Chromium, when one is installed. A custom
    # `config.pdf_renderer` (any callable taking the HTML and PDF paths) replaces it.
    module PDF
      BROWSERS = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "google-chrome", "google-chrome-stable", "chromium", "chromium-browser"
      ].freeze

      module_function

      def render(html_path, pdf_path, config: PlanDriven.configuration)
        return config.pdf_renderer.call(html_path.to_s, pdf_path.to_s) && File.exist?(pdf_path) if config.pdf_renderer

        browser = self.browser
        return false unless browser

        system(browser, "--headless", "--disable-gpu", "--no-pdf-header-footer", "--no-sandbox",
               "--print-to-pdf=#{pdf_path}", "file://#{File.expand_path(html_path)}",
               out: File::NULL, err: File::NULL)
        File.exist?(pdf_path)
      end

      def browser
        BROWSERS.find do |candidate|
          candidate.start_with?("/") ? File.executable?(candidate) : executable_on_path?(candidate)
        end
      end

      def executable_on_path?(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
      end
    end
  end
end
