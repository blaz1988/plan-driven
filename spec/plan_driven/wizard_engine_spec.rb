# frozen_string_literal: true

require "open3"

RSpec.describe "The wizard engine in a Rails app" do
  it "renders every step for local requests and refuses others" do
    script = File.expand_path("../wizard/app.rb", __dir__)
    output, status = Open3.capture2e({ "APP_ROOT" => @root.to_s }, RbConfig.ruby, script)
    expect(status).to be_success, output

    expect(output.lines.map(&:chomp).grep(/\A\d{3} /)).to eq([
                                                               "200 /plan_driven true",
                                                               "200 /plan_driven/plans/new true",
                                                               "200 /plan_driven/plans/PD-1 true",
                                                               "200 /plan_driven/plans/PD-1/approve true",
                                                               "200 /plan_driven/plans/PD-1/tickets true",
                                                               "200 /plan_driven/plans/PD-1/agents true",
                                                               "200 /plan_driven/plans/PD-1/finish true",
                                                               "404 /plan_driven/jobs/0000000000000000 true",
                                                               "403 remote"
                                                             ])
  end
end
